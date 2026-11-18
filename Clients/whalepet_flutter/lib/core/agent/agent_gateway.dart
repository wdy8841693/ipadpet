import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_protocol.dart';

/// 网关连接状态（UI 只关心这四个）。
enum AgentConnectionState {
  /// 未连接：没配置服务器，或用户手动断开。
  disconnected,

  /// 正在建连 / 重连中。
  connecting,

  /// 已握手，可以发命令。
  connected,

  /// 不可恢复的错误（401/403 等），需要用户改配置。
  failed,
}

/// 连接层异常：`retryable` 决定要不要走退避重连（§8.10）。
class AgentGatewayException implements Exception {
  AgentGatewayException(this.message, {this.retryable = true, this.statusCode});

  final String message;
  final bool retryable;
  final int? statusCode;

  @override
  String toString() => 'AgentGatewayException($message, retryable=$retryable)';
}

/// 文本 Agent 通道（`WS /api/agent`）的抽象。
///
/// 平台无关：Android / macOS / Windows 都实现同一份协议，只有地址与凭证来源不同。
abstract interface class AgentGateway {
  /// 服务端事件流。
  Stream<AgentServerEvent> get events;

  /// 连接状态流。
  Stream<AgentConnectionState> get states;

  /// 当前状态。
  AgentConnectionState get state;

  /// 建立连接（含健康检查与握手）；重复调用是安全的。
  Future<void> connect();

  /// 发送文本命令。
  Future<void> sendCommand({
    required String requestId,
    required String text,
    String source = 'text',
  });

  /// 请求取消（只承诺桥接层停止等待，§8.8）。
  Future<void> cancel(String requestId);

  /// 主动断开，且不再自动重连。
  Future<void> disconnect();

  /// 释放资源。
  Future<void> dispose();
}

/// 基于 `dart:io` WebSocket 的实现：零第三方依赖，桌面与移动端通用。
///
/// 行为约定（对应 `docs/CROSS_PLATFORM.md` §8.10）：
///   - 先打 `/api/health`，401/403 视为配置错误，不重试；
///   - 断线按 1/2/4/8/16/30 秒退避，收到 `ready` 后重置；
///   - WS ping 超时即关闭旧连接，旧连接的迟到事件按 generation 丢弃；
///   - 按 `event_id` 去重，`hello` 上报 `last_received_event_id` 让服务端补发。
class WebSocketAgentGateway implements AgentGateway {
  WebSocketAgentGateway({
    required this.serverUri,
    required this.token,
    required this.clientId,
    this.conversationId = kDefaultConversationId,
    this.deviceKind = 'windows',
    this.subscriptionsAnnouncements = true,
    this.healthTimeout = const Duration(seconds: 6),
    this.pingInterval = const Duration(seconds: 20),
    this.maxSeenEventIds = 200,
  });

  /// 服务端地址（http/https 或 ws/wss 均可，内部统一规范化）。
  final Uri serverUri;

  /// Bearer 令牌。
  final String token;

  /// 本机持久化的客户端 id。
  final String clientId;

  final String conversationId;
  final String deviceKind;
  final bool subscriptionsAnnouncements;
  final Duration healthTimeout;
  final Duration pingInterval;
  final int maxSeenEventIds;

  final StreamController<AgentServerEvent> _events =
      StreamController<AgentServerEvent>.broadcast();
  final StreamController<AgentConnectionState> _states =
      StreamController<AgentConnectionState>.broadcast();

  AgentConnectionState _state = AgentConnectionState.disconnected;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _retryTimer;
  int _attempt = 0;
  int _generation = 0;
  bool _disposed = false;
  bool _connectInFlight = false;
  Future<void>? _pendingConnect;
  String? _lastReceivedEventId;
  final List<String> _seenEventIds = <String>[];
  final Set<String> _seenEventIdSet = <String>{};
  final Map<String, Completer<void>> _readyWaiters =
      <String, Completer<void>>{};

  @override
  Stream<AgentServerEvent> get events => _events.stream;

  @override
  Stream<AgentConnectionState> get states => _states.stream;

  @override
  AgentConnectionState get state => _state;

  /// 最近一次收到的事件 id（重连时用它请求补发）。
  String? get lastReceivedEventId => _lastReceivedEventId;

  /// 规范化后的 WebSocket 地址。
  Uri get agentWebSocketUri => _resolve('/api/agent', scheme: 'ws');

  /// 规范化后的健康检查地址。
  Uri get healthUri => _resolve('/api/health', scheme: 'http');

  Uri _resolve(String path, {required String scheme}) {
    final String host = serverUri.host;
    final int? port = serverUri.hasPort ? serverUri.port : null;
    final String realScheme = serverUri.scheme == 'wss' || serverUri.scheme == 'https'
        ? (scheme == 'ws' ? 'wss' : 'https')
        : scheme;
    return Uri(
      scheme: realScheme,
      host: host,
      port: port,
      path: path,
    );
  }

  @override
  Future<void> connect() {
    final Future<void>? inFlight = _pendingConnect;
    if (inFlight != null) return inFlight;
    final Future<void> attempt = _connectOnce().whenComplete(() {
      _pendingConnect = null;
    });
    _pendingConnect = attempt;
    return attempt;
  }

  Future<void> _connectOnce() async {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connectInFlight = true;
    _setState(AgentConnectionState.connecting);
    final int generation = ++_generation;
    AgentGatewayException? connectFailure;
    try {
      await _healthCheck(generation);
      final WebSocket socket = await WebSocket.connect(
        agentWebSocketUri.toString(),
        headers: <String, dynamic>{'Authorization': 'Bearer $token'},
        compression: CompressionOptions.compressionOff,
      ).timeout(healthTimeout);
      if (_disposed || generation != _generation) {
        unawaited(socket.close());
        return;
      }
      socket.pingInterval = pingInterval;
      _socket = socket;
      _socketSubscription = socket.listen(
        (dynamic data) => _onData(data, generation),
        onError: (Object error, StackTrace _) => _onSocketDown(generation, error),
        onDone: () => _onSocketDown(generation, null),
        cancelOnError: false,
      );
      _send(buildHelloMessage(
        clientId: clientId,
        conversationId: conversationId,
        deviceKind: deviceKind,
        subscriptionsAnnouncements: subscriptionsAnnouncements,
        lastReceivedEventId: _lastReceivedEventId,
      ));
      // 等待 ready 才能算连接成功（handshake 完成）。
      final Completer<void> ready = _readyWaiter(generation);
      await ready.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw AgentGatewayException('握手超时：服务端没有回 ready');
        },
      );
      _attempt = 0;
      _setState(AgentConnectionState.connected);
    } on AgentGatewayException catch (error) {
      connectFailure = error;
      _failConnection(generation, error);
    } on TimeoutException {
      connectFailure = AgentGatewayException('连接超时：检查地址与网络');
      _failConnection(generation, connectFailure);
    } on SocketException catch (error) {
      connectFailure = AgentGatewayException('连接失败：${error.message}');
      _failConnection(generation, connectFailure);
    } on WebSocketException catch (error) {
      final String message = error.message;
      final bool auth = message.contains('401') || message.contains('403');
      connectFailure = AgentGatewayException(
        auth ? '令牌被拒绝（401/403），请检查访问令牌' : 'WebSocket 握手失败：$message',
        retryable: !auth,
      );
      _failConnection(generation, connectFailure);
    } catch (error) {
      connectFailure = AgentGatewayException('连接异常：$error');
      _failConnection(generation, connectFailure);
    } finally {
      // 必须先清掉 in-flight 标记再安排重试：此前在 catch 中调用
      // _scheduleReconnect()，而它看到 _connectInFlight=true 就直接返回，
      // 导致一次连接失败后再也不会重试。
      _connectInFlight = false;
      if (connectFailure?.retryable == true && !_disposed) {
        _scheduleReconnect(generation);
      }
    }
  }

  /// 健康检查：先确认服务在线，401/403 直接放弃重试。
  Future<void> _healthCheck(int generation) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = healthTimeout
      ..autoUncompress = true;
    try {
      final HttpClientRequest request =
          await client.getUrl(healthUri).timeout(healthTimeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final HttpClientResponse response =
          await request.close().timeout(healthTimeout);
      await response.drain<void>();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw AgentGatewayException(
          '令牌被拒绝（${response.statusCode}），请重新复制 ~/.dsh/whalepet/ipad-token',
          retryable: false,
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode != 200) {
        throw AgentGatewayException(
          '健康检查返回 ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
    } finally {
      client.close(force: true);
      // generation 只用于标记「这次尝试是否还有效」，这里不做事，保留参数便于扩展。
      assert(generation > 0);
    }
  }

  Completer<void> _readyWaiter(int generation) {
    final String key = generation.toString();
    return _readyWaiters.putIfAbsent(key, Completer<void>.new);
  }

  void _onData(dynamic data, int generation) {
    if (_disposed || generation != _generation) return;
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    final AgentServerEvent? event = parseAgentServerEvent(decoded);
    if (event == null) return;
    if (!_markSeen(event.eventId)) return;

    if (event is AgentReadyEvent) {
      final Completer<void>? waiter = _readyWaiters.remove(generation.toString());
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
    if (!_events.isClosed) _events.add(event);
  }

  /// 事件去重；返回 false 表示这条已经处理过。
  bool _markSeen(String? eventId) {
    if (eventId == null) return true;
    if (_seenEventIdSet.contains(eventId)) return false;
    _seenEventIdSet.add(eventId);
    _seenEventIds.add(eventId);
    _lastReceivedEventId = eventId;
    while (_seenEventIds.length > maxSeenEventIds) {
      final String removed = _seenEventIds.removeAt(0);
      _seenEventIdSet.remove(removed);
    }
    return true;
  }

  void _onSocketDown(int generation, Object? error) {
    if (_disposed || generation != _generation) return;
    _teardownSocket();
    if (_state != AgentConnectionState.failed) {
      _setState(AgentConnectionState.disconnected);
    }
    _scheduleReconnect(generation);
  }

  void _failConnection(int generation, AgentGatewayException error) {
    if (_disposed || generation != _generation) return;
    _teardownSocket();
    _setState(error.retryable
        ? AgentConnectionState.disconnected
        : AgentConnectionState.failed);
    if (!_events.isClosed) {
      _events.add(AgentErrorEvent(
        code: 'gateway',
        message: error.message,
        retryable: error.retryable,
        receivedAt: DateTime.now().toUtc(),
      ));
    }
  }

  /// 1/2/4/8/16/30 秒退避（30 秒封顶）。
  void _scheduleReconnect(int generation) {
    if (_disposed || generation != _generation) return;
    if (_state == AgentConnectionState.failed) return;
    if (_connectInFlight) return;
    _retryTimer?.cancel();
    const List<int> backoff = <int>[1, 2, 4, 8, 16, 30];
    final int seconds = backoff[_attempt.clamp(0, backoff.length - 1)];
    _attempt = (_attempt + 1).clamp(0, backoff.length - 1);
    _setState(AgentConnectionState.connecting);
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (_disposed || generation != _generation) return;
      unawaited(connect());
    });
  }

  void _teardownSocket() {
    final WebSocket? socket = _socket;
    _socket = null;
    final StreamSubscription<dynamic>? subscription = _socketSubscription;
    _socketSubscription = null;
    unawaited(subscription?.cancel());
    if (socket != null) {
      unawaited(socket.close(WebSocketStatus.normalClosure).catchError((_) {}));
    }
    for (final Completer<void> waiter in _readyWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(
          AgentGatewayException('连接在握手前断开'),
        );
      }
    }
    _readyWaiters.clear();
  }

  void _send(Map<String, dynamic> message) {
    final WebSocket? socket = _socket;
    if (socket == null) return;
    try {
      socket.add(jsonEncode(message));
    } catch (_) {
      // 连接已经断了：交给 onDone 处理。
    }
  }

  void _setState(AgentConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  @override
  Future<void> sendCommand({
    required String requestId,
    required String text,
    String source = 'text',
  }) async {
    final String? normalized = normalizeCommandText(text);
    if (normalized == null) {
      throw AgentGatewayException('命令内容为空或超过 $kMaxCommandChars 字符', retryable: false);
    }
    if (!isValidAgentId(requestId)) {
      throw AgentGatewayException('request_id 不合法', retryable: false);
    }
    if (_state != AgentConnectionState.connected) {
      throw AgentGatewayException('还没连上服务端', retryable: true);
    }
    _send(buildCommandMessage(
      requestId: requestId,
      text: normalized,
      clientId: clientId,
      conversationId: conversationId,
      source: source,
    ));
  }

  @override
  Future<void> cancel(String requestId) async {
    _send(buildCancelMessage(requestId: requestId, clientId: clientId));
  }

  @override
  Future<void> disconnect() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    _generation++;
    _teardownSocket();
    _setState(AgentConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _generation++;
    _teardownSocket();
    await _events.close();
    await _states.close();
  }
}
