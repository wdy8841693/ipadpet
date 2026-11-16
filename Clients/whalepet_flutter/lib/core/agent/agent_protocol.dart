import 'dart:math';

/// `/api/agent` 文本协议（protocol 2）的常量、消息编码与解析。
///
/// 规则来源：`docs/CROSS_PLATFORM.md` §8；服务端实现见
/// `Plugin/whalepet-dsh-bridge/src/agent-protocol.js` 与 `agent-channel.js`。
///
/// 本文件是**纯 Dart**：不 import Flutter，也不碰网络，便于用 `dart test` 直接验证。

/// 协议版本（服务端只接受 <= 该值）。
const int kAgentProtocolVersion = 2;

/// 默认会话 id：所有设备共享同一个宠物长期会话。
const String kDefaultConversationId = 'whalepet-main';

/// 命令文本最大长度（字符，服务端同样是 16000）。
const int kMaxCommandChars = 16000;

/// 标识符规则：字母数字下划线连字符，1~80 字符。
final RegExp kAgentIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

/// 任务状态集合（与服务端 `TASK_STATES` 一致）。
const List<String> kAgentTaskStates = <String>[
  'queued',
  'started',
  'approval',
  'interrupted',
  'finished',
  'failed',
];

/// 是否合法标识符。
bool isValidAgentId(String? value) =>
    value != null && kAgentIdPattern.hasMatch(value);

/// 规范化命令文本：去首尾空白；空或超长返回 null。
String? normalizeCommandText(String? value) {
  if (value == null) return null;
  final String text = value.trim();
  if (text.isEmpty) return null;
  if (text.length > kMaxCommandChars) return null;
  return text;
}

/// 生成一个 request_id（`[A-Za-z0-9_-]`，满足服务端校验）。
///
/// 用「时间戳 + 随机后缀」而不是 UUID：断线重试时要能复用同一个 id，
/// 所以 id 必须由调用方保存，而不是每次生成新的（§8.4、§8.10）。
String newRequestId({DateTime? now, Random? random}) {
  final int stamp = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
  final Random rnd = random ?? Random();
  final String suffix = rnd.nextInt(0x1000000).toRadixString(36);
  return 'req-$stamp-$suffix';
}

/// 生成一个客户端 id（首次安装时生成并持久化，§8.2）。
String newClientId({String prefix = 'windows', Random? random}) {
  final Random rnd = random ?? Random();
  final String suffix = rnd.nextInt(0x100000000).toRadixString(36);
  return '$prefix-$suffix';
}

// -- 客户端 → 服务端 -------------------------------------------------------

/// 握手消息（§8.3）。
Map<String, dynamic> buildHelloMessage({
  required String clientId,
  String conversationId = kDefaultConversationId,
  String deviceKind = 'windows',
  List<String> capabilities = const <String>['local-tts'],
  bool subscriptionsAnnouncements = true,
  String? lastReceivedEventId,
}) {
  return <String, dynamic>{
    'type': 'hello',
    'protocol': kAgentProtocolVersion,
    'client_id': clientId,
    'conversation_id': conversationId,
    'device_kind': deviceKind,
    'capabilities': capabilities,
    'subscriptions': <String, dynamic>{
      'announcements': subscriptionsAnnouncements,
    },
    'last_received_event_id': lastReceivedEventId,
  };
}

/// 命令消息（§8.4）。
Map<String, dynamic> buildCommandMessage({
  required String requestId,
  required String text,
  required String clientId,
  String conversationId = kDefaultConversationId,
  String source = 'text',
}) {
  return <String, dynamic>{
    'type': 'command',
    'request_id': requestId,
    'client_id': clientId,
    'conversation_id': conversationId,
    'text': text,
    'source': source,
  };
}

/// 取消消息（§8.8）。
Map<String, dynamic> buildCancelMessage({
  required String requestId,
  required String clientId,
}) {
  return <String, dynamic>{
    'type': 'cancel',
    'request_id': requestId,
    'client_id': clientId,
  };
}

// -- 服务端 → 客户端 -------------------------------------------------------

/// 服务端事件基类。
sealed class AgentServerEvent {
  const AgentServerEvent({this.eventId, this.receivedAt});

  /// 服务端事件 id；`ready` / `error` 没有该字段。
  final String? eventId;

  /// 客户端收到该事件的本地时间（用于 TTL、补发窗口判断）。
  final DateTime? receivedAt;
}

/// 握手成功（§8.3）。
class AgentReadyEvent extends AgentServerEvent {
  const AgentReadyEvent({
    required this.protocol,
    required this.conversationId,
    required this.agentReady,
    this.serverTime,
    super.eventId,
    super.receivedAt,
  });

  final int protocol;
  final String conversationId;
  final bool agentReady;
  final DateTime? serverTime;
}

/// 语音配置下发（§11.3）。Windows 第一阶段只用来回显设置，不重建 KWS。
class AgentVoiceConfigEvent extends AgentServerEvent {
  const AgentVoiceConfigEvent({
    required this.revision,
    required this.wakePhrase,
    required this.wakeAliases,
    required this.wakeAck,
    required this.listenTimeoutMs,
    super.eventId,
    super.receivedAt,
  });

  final int revision;
  final String wakePhrase;
  final List<String> wakeAliases;
  final String wakeAck;
  final int listenTimeoutMs;
}

/// 私有任务事件（§8.5）。
class AgentTaskEvent extends AgentServerEvent {
  const AgentTaskEvent({
    required this.requestId,
    required this.state,
    this.text,
    this.taskId,
    this.originClientId,
    super.eventId,
    super.receivedAt,
  });

  final String requestId;
  final String state;
  final String? text;
  final String? taskId;
  final String? originClientId;

  /// 是否是终态（失败 / 完成 / 中断）。
  bool get isTerminal =>
      state == 'finished' || state == 'failed' || state == 'interrupted';
}

/// 最终回答（§8.6）。
class AgentResponseEvent extends AgentServerEvent {
  const AgentResponseEvent({
    required this.requestId,
    required this.displayText,
    required this.speechText,
    required this.isFinal,
    this.taskId,
    super.eventId,
    super.receivedAt,
  });

  final String requestId;

  /// 上屏文本（可含 Markdown）。
  final String displayText;

  /// 可直接播报的文本。
  final String speechText;

  final bool isFinal;
  final String? taskId;
}

/// 全局通知（§8.7，其它 DSH 会话的任务进展）。
class AgentAnnouncementEvent extends AgentServerEvent {
  const AgentAnnouncementEvent({
    required this.scope,
    required this.state,
    required this.displayText,
    required this.speechText,
    super.eventId,
    super.receivedAt,
  });

  final String scope;
  final String state;
  final String displayText;
  final String speechText;
}

/// 错误（§8.8）。
class AgentErrorEvent extends AgentServerEvent {
  const AgentErrorEvent({
    required this.code,
    required this.message,
    required this.retryable,
    this.requestId,
    super.eventId,
    super.receivedAt,
  });

  final String code;
  final String message;
  final bool retryable;
  final String? requestId;
}

/// 不认识的事件：保留原文，便于日志排查，不影响连接。
class AgentUnknownServerEvent extends AgentServerEvent {
  const AgentUnknownServerEvent({
    required this.type,
    required this.raw,
    super.eventId,
    super.receivedAt,
  });

  final String type;
  final Map<String, dynamic> raw;
}

/// 解析一条服务端消息；不是 JSON 对象时返回 null。
AgentServerEvent? parseAgentServerEvent(
  Object? decoded, {
  DateTime? receivedAt,
}) {
  if (decoded is! Map<String, dynamic>) return null;
  final Object? rawType = decoded['type'];
  final String type = rawType is String ? rawType : '';
  final String? eventId = _string(decoded['event_id']);
  final DateTime stamp = receivedAt ?? DateTime.now().toUtc();

  switch (type) {
    case 'ready':
      return AgentReadyEvent(
        protocol: _int(decoded['protocol'], fallback: kAgentProtocolVersion),
        conversationId:
            _string(decoded['conversation_id']) ?? kDefaultConversationId,
        agentReady: decoded['agent_ready'] == true,
        serverTime: _date(decoded['server_time']),
        eventId: eventId,
        receivedAt: stamp,
      );
    case 'voice_config':
      return AgentVoiceConfigEvent(
        revision: _int(decoded['revision'], fallback: 0),
        wakePhrase: _string(decoded['wake_phrase']) ?? '',
        wakeAliases: _stringList(decoded['wake_aliases']),
        wakeAck: _string(decoded['wake_ack']) ?? '我在',
        listenTimeoutMs: _int(decoded['listen_timeout_ms'], fallback: 10000),
        eventId: eventId,
        receivedAt: stamp,
      );
    case 'task':
      final String? requestId = _string(decoded['request_id']);
      final String? state = _string(decoded['state']);
      if (requestId == null || state == null) {
        return AgentUnknownServerEvent(
          type: type,
          raw: decoded,
          eventId: eventId,
          receivedAt: stamp,
        );
      }
      return AgentTaskEvent(
        requestId: requestId,
        state: state,
        text: _string(decoded['text']),
        taskId: _string(decoded['task_id']),
        originClientId: _string(decoded['origin_client_id']),
        eventId: eventId,
        receivedAt: stamp,
      );
    case 'response':
      final String? requestId = _string(decoded['request_id']);
      if (requestId == null) {
        return AgentUnknownServerEvent(
          type: type,
          raw: decoded,
          eventId: eventId,
          receivedAt: stamp,
        );
      }
      return AgentResponseEvent(
        requestId: requestId,
        displayText: _string(decoded['display_text']) ?? '',
        speechText: _string(decoded['speech_text']) ?? '',
        isFinal: decoded['final'] != false,
        taskId: _string(decoded['task_id']),
        eventId: eventId,
        receivedAt: stamp,
      );
    case 'announcement':
      return AgentAnnouncementEvent(
        scope: _string(decoded['scope']) ?? 'global',
        state: _string(decoded['state']) ?? '',
        displayText: _string(decoded['display_text']) ?? '',
        speechText: _string(decoded['speech_text']) ?? '',
        eventId: eventId,
        receivedAt: stamp,
      );
    case 'error':
      return AgentErrorEvent(
        code: _string(decoded['code']) ?? 'error',
        message: _string(decoded['message']) ?? '',
        retryable: decoded['retryable'] == true,
        requestId: _string(decoded['request_id']),
        eventId: eventId,
        receivedAt: stamp,
      );
    default:
      return AgentUnknownServerEvent(
        type: type,
        raw: decoded,
        eventId: eventId,
        receivedAt: stamp,
      );
  }
}

String? _string(Object? value) => value is String && value.isNotEmpty ? value : null;

int _int(Object? value, {required int fallback}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return fallback;
}

DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().toList(growable: false);
}
