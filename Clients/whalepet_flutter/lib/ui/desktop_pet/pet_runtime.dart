import 'dart:async';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../core/agent/agent_gateway.dart';
import '../../core/agent/agent_protocol.dart';
import '../../core/config/app_paths.dart';
import '../../core/config/app_settings.dart';
import '../../core/config/token_store.dart';
import '../../core/pet/dialogue.dart';
import '../../core/pet/pet_behavior.dart';
import '../../core/pet/pet_state.dart';
import '../../core/pet/pet_vitals.dart';
import '../../core/platform/desktop_window.dart';
import '../../core/platform/window_placement.dart';
import '../../core/storage/pet_save.dart';
import '../../core/storage/pet_save_store.dart';
import '../../core/voice/speech_output.dart';
import '../../core/voice/speech_queue.dart';
import 'pet_layout.dart';

/// 当前展开的面板。
enum PetPanel { none, chat, settings }

/// 聊天面板里的一条消息。
class ChatMessage {
  ChatMessage({required this.fromUser, required this.text, required this.at});

  final bool fromUser;
  final String text;
  final DateTime at;
}

/// 桌宠的运行时：状态机、数值、窗口移动、Agent 通道、播报队列的唯一持有者。
///
/// 边界（`docs/CROSS_PLATFORM.md` §7.1）：UI 只读状态 + 转发用户动作，
/// 平台能力（窗口 / TTS / 网络）都通过适配层进来，便于替换与测试。
class PetRuntime extends ChangeNotifier {
  PetRuntime({
    required this.paths,
    required this.window,
    required this.speech,
    Random? random,
  }) : _random = random ?? Random() {
    _behavior = PetBehavior(random: _random);
    _dialogue = Dialogue(random: _random);
  }

  final AppPaths paths;
  final DesktopWindowAdapter window;
  final SpeechOutputAdapter speech;
  final Random _random;

  static const int _tickMs = 33;
  static const double _walkSpeed = 34;

  late final PetBehavior _behavior;
  late final Dialogue _dialogue;

  SettingsStore? _settingsStore;
  PetSaveStore? _saveStore;
  AppSettings _settings = AppSettings();
  PetVitals _vitals = PetVitals();
  String _petName = '小鲸';
  DateTime _bornAtUtc = DateTime.now().toUtc();
  int _totalFeeds = 0;
  int _totalPets = 0;

  WebSocketAgentGateway? _gateway;
  StreamSubscription<AgentServerEvent>? _eventSubscription;
  StreamSubscription<AgentConnectionState>? _stateSubscription;
  StreamSubscription<SpeechOutputEvent>? _speechSubscription;
  AgentConnectionState _connectionState = AgentConnectionState.disconnected;
  String? _token;
  String _clientId = '';

  final SpeechQueue _speechQueue = SpeechQueue();
  final List<ChatMessage> _chat = <ChatMessage>[];
  bool _speechAvailable = false;
  bool _speaking = false;
  String? _speakingId;

  PetState _petState = PetState.idle;
  double _transientRemaining = 0;
  bool _dragging = false;
  double _walkDirection = 1;
  double _swimPhase = 0;
  double _swimBaseTop = 0;
  double _behaviorTimer = 0;
  double _bubbleRemaining = 0;
  double _saveTimer = 0;
  double _hitTestTimer = 0;
  double _elapsed = 0;

  String? _bubbleText;
  String? _lastError;
  String? _activeRequestId;
  bool _announcedConnection = false;
  String _wakePhrase = '小鲸小鲸';

  PetPanel _panel = PetPanel.none;
  bool _menuOpen = false;
  bool _clickThrough = false;
  bool _windowReady = false;
  bool _started = false;
  bool _servicesStarted = false;
  bool _disposed = false;

  Timer? _ticker;
  WindowRect _bounds = const WindowRect(left: 0, top: 0, width: PetLayout.windowWidth, height: PetLayout.windowHeight);
  WorkArea _area = const WorkArea(left: 0, top: 0, width: 1920, height: 1080);

  // -- 只读状态（UI 读这些）--------------------------------------------------

  AppSettings get settings => _settings;
  PetVitals get vitals => _vitals;
  PetState get petState => _petState;
  String get petName => _petName;
  String? get bubbleText => _bubbleText;
  String? get lastError => _lastError;
  PetPanel get panel => _panel;
  bool get menuOpen => _menuOpen;
  bool get clickThrough => _clickThrough;
  bool get speechAvailable => _speechAvailable;
  bool get speaking => _speaking;
  AgentConnectionState get connectionState => _connectionState;
  String get wakePhrase => _wakePhrase;

  /// 本机客户端 id（设置面板里展示，便于服务端日志对照）。
  String get runtimeClientId => _clientId;
  List<ChatMessage> get chat => List<ChatMessage>.unmodifiable(_chat);
  double get elapsedSeconds => _elapsed;

  /// 走路朝向（1 = 向右，-1 = 向左），决定立绘是否水平翻转。
  double get walkDirection => _walkDirection;
  bool get isConnected => _connectionState == AgentConnectionState.connected;

  /// 连接状态的中文说明（显示在面板标题上）。
  String get connectionLabel {
    switch (_connectionState) {
      case AgentConnectionState.connected:
        return '已连接';
      case AgentConnectionState.connecting:
        return '连接中…';
      case AgentConnectionState.failed:
        return '连接失败';
      case AgentConnectionState.disconnected:
        return _settings.isConfigured ? '未连接' : '未配置';
    }
  }

  // -- 生命周期 -------------------------------------------------------------

  /// 快速启动：读配置 → 读存档 → 建窗口。**必须先跑完再 runApp**，
  /// 这样第一帧出来窗口就已经是宠物尺寸，不会先闪一个大白窗。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await paths.ensureCreated();
    _settingsStore = SettingsStore(file: paths.settingsFile);
    _settings = await _settingsStore!.load();
    await _loadPet();
    await _loadIdentity();
    await _initWindow();
    notifyListeners();
  }

  /// 慢启动：拉起播报引擎、连 DSH、开帧循环。可以 runApp 之后再 await。
  Future<void> startServices() async {
    if (_servicesStarted) return;
    _servicesStarted = true;
    await _initSpeech();
    await _connectIfConfigured();
    _ticker = Timer.periodic(const Duration(milliseconds: _tickMs), (_) => _onTick());
    notifyListeners();
  }

  Future<void> _loadPet() async {
    _saveStore = PetSaveStore(directory: paths.saveDirectory);
    final PetSave save = await _saveStore!.load();
    _vitals = save.vitals;
    _petName = save.petName;
    _totalFeeds = save.totalFeeds;
    _totalPets = save.totalPets;
    _bornAtUtc = save.bornAtUtc;
    final Duration offline = DateTime.now().toUtc().difference(save.lastTickUtc);
    _vitals.settleOffline(offline);
  }

  Future<void> _loadIdentity() async {
    final ClientIdStore idStore = ClientIdStore(file: paths.clientIdFile);
    String? id = await idStore.read();
    if (id == null) {
      id = newClientId(random: _random);
      await idStore.write(id);
    }
    _clientId = id;
    _token = await TokenStore(file: paths.tokenFile).read();
  }

  Future<void> _initWindow() async {
    try {
      await window.initialize();
      await window.setAlwaysOnTop(_settings.alwaysOnTop);
      await window.setSkipTaskbar(true);
      _area = await window.workArea();
      _bounds = _initialBounds();
      await window.setBounds(_bounds);
      _windowReady = true;
    } catch (error) {
      _lastError = '窗口初始化失败：$error';
    }
  }

  WindowRect _initialBounds() {
    final double defaultLeft =
        _area.left + (_area.width - PetLayout.windowWidth) / 2;
    final double defaultTop = _area.bottom - PetLayout.windowHeight - 8;
    final double left = _settings.windowX ?? defaultLeft;
    final double top = _settings.windowY ?? defaultTop;
    return clampToWorkArea(
      WindowRect(
        left: left,
        top: top,
        width: PetLayout.windowWidth,
        height: PetLayout.windowHeight,
      ),
      _area,
      minVisible: 0,
    );
  }

  Future<void> _initSpeech() async {
    try {
      await speech.initialize();
      _speechAvailable = true;
      _speechSubscription = speech.events.listen(_onSpeechEvent);
    } catch (error) {
      _speechAvailable = false;
      _lastError = '系统播报不可用（只上屏不朗读）：$error';
    }
  }

  Future<void> _connectIfConfigured() async {
    final Uri? uri = _settings.parsedServerUri;
    final String? token = _token;
    if (uri == null) {
      _setConnectionState(AgentConnectionState.disconnected);
      return;
    }
    if (token == null || token.isEmpty) {
      _setConnectionState(AgentConnectionState.disconnected);
      _lastError = '还没填访问令牌（~/.dsh/whalepet/ipad-token）';
      return;
    }
    final WebSocketAgentGateway gateway = WebSocketAgentGateway(
      serverUri: uri,
      token: token,
      clientId: _clientId,
      subscriptionsAnnouncements: _settings.subscriptionsAnnouncements,
    );
    _gateway = gateway;
    _eventSubscription = gateway.events.listen(_onAgentEvent);
    _stateSubscription = gateway.states.listen(_setConnectionState);
    unawaited(gateway.connect().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    unawaited(_eventSubscription?.cancel());
    unawaited(_stateSubscription?.cancel());
    unawaited(_speechSubscription?.cancel());
    unawaited(_gateway?.dispose());
    unawaited(speech.dispose());
    unawaited(window.dispose());
    super.dispose();
  }

  // -- 帧循环 ---------------------------------------------------------------

  void _onTick() {
    if (_disposed) return;
    const double dt = _tickMs / 1000.0;
    _elapsed += dt;
    if (_windowReady) {
      _vitals.tick(dt, sleeping: _petState == PetState.sleep);
      if (_transientRemaining > 0) {
        _transientRemaining -= dt;
        if (_transientRemaining <= 0) _finishTransient();
      }
      _behaviorTimer += dt;
      if (_behaviorTimer >= 2.5) {
        _behaviorTimer = 0;
        _maybeSwitchAutonomous();
      }
      _moveTick(dt);
      if (_bubbleRemaining > 0) {
        _bubbleRemaining -= dt;
        if (_bubbleRemaining <= 0) _bubbleText = null;
      }
      if (_settings.clickThroughWhereTransparent) {
        _hitTestTimer += dt;
        if (_hitTestTimer >= 0.1) {
          _hitTestTimer = 0;
          unawaited(_updateClickThrough());
        }
      }
      _saveTimer += dt;
      if (_saveTimer >= 15) {
        _saveTimer = 0;
        unawaited(persistNow());
      }
    }
    notifyListeners();
  }

  void _moveTick(double dt) {
    if (_petState == PetState.walk) {
      final double nextLeft = _bounds.left + _walkDirection * _walkSpeed * dt;
      final WindowRect next = _bounds.copyWith(left: nextLeft);
      final WindowRect clamped = clampToWorkArea(next, _area, minVisible: 0);
      if (clamped.left != next.left) _walkDirection = -_walkDirection;
      if (clamped.left != _bounds.left) {
        _bounds = clamped;
        unawaited(window.setPosition(_bounds.left, _bounds.top));
      }
    } else if (_petState == PetState.swim) {
      _swimPhase += dt;
      final double top = _swimBaseTop + sin(_swimPhase * 1.1) * 10;
      final WindowRect clamped = clampToWorkArea(
        _bounds.copyWith(top: top),
        _area,
        minVisible: 0,
      );
      if (clamped.top != _bounds.top) {
        _bounds = clamped;
        unawaited(window.setPosition(_bounds.left, _bounds.top));
      }
    }
  }

  void _maybeSwitchAutonomous() {
    if (!_windowReady) return;
    if (_petState.isBusy || _panel != PetPanel.none || _menuOpen) return;
    final PetState next = _behavior.nextAutonomousState(
      _petState,
      isDragging: _dragging,
      isBusy: false,
    );
    if (next == _petState) return;
    // 精力够就不睡：睡觉是数值驱动，不是随机行为。
    if (next == PetState.sleep && _vitals.energy > 55) return;
    if (_petState == PetState.sleep && next != PetState.sleep) {
      // 睡醒先回待机。
      _setState(PetState.idle);
      return;
    }
    _setState(next);
    if (_random.nextDouble() < 0.35) {
      final String? line =
          _dialogue.line(state: next, vitals: _vitals, petName: _petName);
      if (line != null) _say(line, seconds: 5);
    }
  }

  void _finishTransient() {
    if (_petState == PetState.happy ||
        _petState == PetState.eat ||
        _petState == PetState.play ||
        _petState == PetState.drag) {
      _setState(_vitals.energy < 20 ? PetState.sleep : PetState.idle);
      _swimPhase = 0;
    }
  }

  void _setState(PetState next) {
    if (_petState == next) return;
    if (next == PetState.swim) _swimBaseTop = _bounds.top;
    _petState = next;
    notifyListeners();
  }

  // -- 鼠标穿透（透明区域不吃点击）-------------------------------------------

  Future<void> _updateClickThrough() async {
    if (!_windowReady) return;
    final ({double x, double y})? cursor = window.cursorPosition();
    if (cursor == null) return;
    // 窗口可能被用户拖动过：每次都以系统真实位置为准。
    _bounds = await window.bounds();
    final Offset local = Offset(cursor.x - _bounds.left, cursor.y - _bounds.top);
    final bool overPet = PetLayout.petRect.contains(local);
    final bool overPanel =
        _panel != PetPanel.none && PetLayout.panelRect.contains(local);
    final bool overMenu = _menuOpen && PetLayout.menuRect.contains(local);
    final bool interactive = overPet || overPanel || overMenu;
    final bool want = !interactive;
    if (want == _clickThrough) return;
    _clickThrough = want;
    await window.setClickThrough(want);
  }

  // -- 互动 ----------------------------------------------------------------

  /// 摸头。
  void petHead() {
    if (_petState == PetState.sleep) {
      _say('zzZ……（睡梦里被摸了摸头）', seconds: 4);
      return;
    }
    _vitals.petHead();
    _totalPets++;
    _setState(PetState.happy);
    _transientRemaining = 2.2;
    _say(
      _dialogue.line(state: PetState.happy, vitals: _vitals, petName: _petName) ??
          '嘿嘿～',
      seconds: 4,
    );
    notifyListeners();
  }

  /// 投喂。
  void feed() {
    if (_petState == PetState.sleep) {
      _say('睡着啦，等会儿再喂嘛……', seconds: 4);
      return;
    }
    if (!_vitals.feed()) {
      _say('已经吃得饱饱的啦！', seconds: 4);
      return;
    }
    _totalFeeds++;
    _setState(PetState.eat);
    _transientRemaining = 2.4;
    _say(
      _dialogue.line(state: PetState.eat, vitals: _vitals, petName: _petName) ??
          '小鱼干！',
      seconds: 4,
    );
    notifyListeners();
  }

  /// 玩耍。
  void play() {
    if (_petState == PetState.sleep) {
      _say('睡着啦，醒了再玩～', seconds: 4);
      return;
    }
    if (_vitals.energy < 8) {
      _say('没力气了……让我睡一会儿', seconds: 4);
      return;
    }
    _vitals.play();
    _setState(PetState.play);
    _transientRemaining = 2.4;
    _say(
      _dialogue.line(state: PetState.play, vitals: _vitals, petName: _petName) ??
          '接住这个泡泡！',
      seconds: 4,
    );
    notifyListeners();
  }

  /// 让宠物去睡觉 / 叫醒。
  void toggleSleep() {
    if (_petState == PetState.sleep) {
      _setState(PetState.idle);
      _say('唔……我醒了', seconds: 3);
    } else if (!_petState.isBusy) {
      _setState(PetState.sleep);
      _say('那我先睡一会儿～', seconds: 3);
    }
  }

  /// 拖动开始（由 UI 在 panStart 时调用）。
  Future<void> beginDrag() async {
    _dragging = true;
    _transientRemaining = 0;
    _setState(PetState.drag);
    await window.startNativeDrag();
  }

  /// 拖动结束。
  Future<void> endDrag() async {
    _dragging = false;
    _transientRemaining = 1.0;
    _bounds = await window.bounds();
    _bounds = clampToWorkArea(_bounds, _area, minVisible: 0);
    await window.setPosition(_bounds.left, _bounds.top);
    notifyListeners();
  }

  // -- 面板 & 菜单 ----------------------------------------------------------

  void openPanel(PetPanel panel) {
    _panel = panel;
    _menuOpen = false;
    if (_clickThrough) {
      _clickThrough = false;
      unawaited(window.setClickThrough(false));
    }
    notifyListeners();
  }

  void closePanel() {
    if (_panel == PetPanel.none) return;
    _panel = PetPanel.none;
    notifyListeners();
  }

  void toggleMenu() {
    _menuOpen = !_menuOpen;
    if (_clickThrough) {
      _clickThrough = false;
      unawaited(window.setClickThrough(false));
    }
    notifyListeners();
  }

  void closeMenu() {
    if (!_menuOpen) return;
    _menuOpen = false;
    notifyListeners();
  }

  // -- 命令 ----------------------------------------------------------------

  /// 发送一条文本命令（聊天面板 / 快捷键都走这里）。
  Future<void> sendText(String raw) async {
    final String? text = normalizeCommandText(raw);
    if (text == null) return;
    // 先把用户的话留在历史里：离线时也不能让它凭空消失。
    _chat.add(ChatMessage(fromUser: true, text: text, at: DateTime.now()));
    notifyListeners();
    final WebSocketAgentGateway? gateway = _gateway;
    if (gateway == null || _connectionState != AgentConnectionState.connected) {
      _say('还没连上 DSH：右键 → 设置，填服务器地址和令牌', seconds: 6);
      return;
    }
    final String requestId = newRequestId(random: _random);
    _activeRequestId = requestId;
    _setState(PetState.thinking);
    _say('收到，我这就去办～', seconds: 3);
    notifyListeners();
    try {
      await gateway.sendCommand(requestId: requestId, text: text);
    } catch (error) {
      _activeRequestId = null;
      _setState(PetState.idle);
      _say('发送失败：$error', seconds: 6);
    }
  }

  void clearChat() {
    _chat.clear();
    notifyListeners();
  }

  /// 保存设置并（必要时）重连。
  Future<void> applySettings(AppSettings next, {String? token}) async {
    final bool serverChanged = next.serverUrl.trim() != _settings.serverUrl.trim();
    _settings = next;
    await _settingsStore?.save(_settings);
    await window.setAlwaysOnTop(next.alwaysOnTop);
    if (token != null) {
      await TokenStore(file: paths.tokenFile).write(token);
      final String trimmed = token.trim();
      _token = trimmed.isEmpty ? null : trimmed;
    }
    final bool tokenChanged = token != null;
    if (serverChanged || tokenChanged) {
      await _restartGateway();
    }
    notifyListeners();
  }

  Future<void> _restartGateway() async {
    await _eventSubscription?.cancel();
    await _stateSubscription?.cancel();
    await _gateway?.dispose();
    _gateway = null;
    _eventSubscription = null;
    _stateSubscription = null;
    _announcedConnection = false;
    _setConnectionState(AgentConnectionState.disconnected);
    await _connectIfConfigured();
  }

  /// 手动重连。
  Future<void> reconnect() async {
    await _restartGateway();
  }

  // -- 播报 ----------------------------------------------------------------

  void _onSpeechEvent(SpeechOutputEvent event) {
    if (event.kind == SpeechOutputEventKind.started) {
      if (_speaking && event.utteranceId == _speakingId) {
        _setState(PetState.speaking);
      }
      return;
    }
    if (event.kind == SpeechOutputEventKind.failed) {
      _lastError = '播报失败：${event.message ?? '未知原因'}';
      notifyListeners();
    }
  }

  void _enqueueSpeech(
    String id, {
    required String text,
    required SpeechPriority priority,
    String? requestId,
  }) {
    if (!_settings.speakResponses || !_speechAvailable) return;
    final bool added = _speechQueue.enqueue(
      SpeechItem(id: id, text: text, priority: priority, requestId: requestId),
    );
    if (added) _pumpSpeech();
  }

  void _pumpSpeech() {
    if (_speaking || !_speechAvailable || !_settings.speakResponses) return;
    final SpeechItem? item = _speechQueue.take();
    if (item == null) return;
    _speaking = true;
    _speakingId = item.id;
    _setState(PetState.speaking);
    unawaited(
      speech.speak(item.id, item.text).then<void>((_) {}).catchError((Object error) {
        _lastError = '播报失败：$error';
      }).whenComplete(() {
        _speaking = false;
        _speakingId = null;
        if (_speechQueue.isEmpty) {
          _setState(_activeRequestId != null ? PetState.thinking : PetState.idle);
        } else {
          _pumpSpeech();
        }
        notifyListeners();
      }),
    );
  }

  // -- Agent 事件 ----------------------------------------------------------

  void _setConnectionState(AgentConnectionState next) {
    if (_connectionState == next) return;
    _connectionState = next;
    if (next == AgentConnectionState.failed) {
      _lastError = '连接失败：检查地址与令牌（右键 → 设置）';
    }
    notifyListeners();
  }

  void _onAgentEvent(AgentServerEvent event) {
    switch (event) {
      case AgentReadyEvent():
        _setConnectionState(AgentConnectionState.connected);
        if (!_announcedConnection) {
          _announcedConnection = true;
          _say('连上 DSH 啦，双击我说话～', seconds: 5);
        }
      case AgentTaskEvent():
        _handleTaskEvent(event);
      case AgentResponseEvent():
        _handleResponseEvent(event);
      case AgentAnnouncementEvent():
        _handleAnnouncement(event);
      case AgentErrorEvent():
        _say(event.message.isEmpty ? '出错了' : event.message, seconds: 8);
        if (event.requestId != null && event.requestId == _activeRequestId) {
          _activeRequestId = null;
          if (!_speaking) _setState(PetState.idle);
        }
      case AgentVoiceConfigEvent():
        if (event.wakePhrase.isNotEmpty) _wakePhrase = event.wakePhrase;
      case AgentUnknownServerEvent():
        break;
    }
    notifyListeners();
  }

  void _handleTaskEvent(AgentTaskEvent event) {
    final String id = event.eventId ?? 'task-${event.requestId}-${event.state}';
    switch (event.state) {
      case 'queued':
      case 'started':
        if (_activeRequestId == event.requestId) _setState(PetState.thinking);
        if (event.text != null) _say(event.text!, seconds: 4);
      case 'approval':
        _say(event.text ?? '需要你确认一下', seconds: 12);
        _enqueueSpeech(
          id,
          text: event.text ?? '需要你确认一下',
          priority: SpeechPriority.completion,
          requestId: event.requestId,
        );
      case 'finished':
        if (_activeRequestId == event.requestId) _activeRequestId = null;
        if (!_speaking && _petState == PetState.thinking) _setState(PetState.idle);
        // 正式回答已经念过时，队列会按 requestId 丢掉这句「做完了」。
        _enqueueSpeech(
          id,
          text: event.text ?? '做完了',
          priority: SpeechPriority.completion,
          requestId: event.requestId,
        );
      case 'failed':
      case 'interrupted':
        if (event.text != null) _say(event.text!, seconds: 6);
        if (_activeRequestId == event.requestId) _activeRequestId = null;
        if (!_speaking && _petState == PetState.thinking) _setState(PetState.idle);
      default:
        if (event.text != null) _say(event.text!, seconds: 4);
    }
  }

  void _handleResponseEvent(AgentResponseEvent event) {
    final String speechText = event.speechText.trim().isNotEmpty
        ? event.speechText.trim()
        : event.displayText.trim();
    if (event.displayText.trim().isNotEmpty) {
      _chat.add(ChatMessage(
        fromUser: false,
        text: event.displayText.trim(),
        at: DateTime.now(),
      ));
    }
    if (speechText.isNotEmpty) _say(speechText, seconds: 14);
    if (_activeRequestId == event.requestId) _activeRequestId = null;
    _enqueueSpeech(
      event.eventId ?? 'resp-${event.requestId}',
      text: speechText,
      priority: SpeechPriority.response,
      requestId: event.requestId,
    );
  }

  void _handleAnnouncement(AgentAnnouncementEvent event) {
    if (!_settings.subscriptionsAnnouncements) return;
    final String text = event.speechText.trim().isNotEmpty
        ? event.speechText.trim()
        : event.displayText.trim();
    if (text.isEmpty) return;
    _say(text, seconds: 10);
    _enqueueSpeech(
      event.eventId ?? 'ann-${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      priority: SpeechPriority.announcement,
    );
  }

  // -- 持久化 --------------------------------------------------------------

  void _say(String text, {double seconds = 6}) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _bubbleText = trimmed;
    _bubbleRemaining = seconds;
    notifyListeners();
  }

  /// 立即落盘（15 秒节流之外：退出、切面板、休眠前调用）。
  Future<void> persistNow() async {
    final PetSaveStore? store = _saveStore;
    if (store == null) return;
    final PetSave save = PetSave(
      vitals: _vitals,
      lastTickUtc: DateTime.now().toUtc(),
      petName: _petName,
      totalFeeds: _totalFeeds,
      totalPets: _totalPets,
      bornAtUtc: _bornAtUtc,
    );
    try {
      await store.save(save);
        await _settingsStore?.save(_settings.copyWith(
        windowX: _bounds.left,
        windowY: _bounds.top,
      ));
    } catch (error) {
      _lastError = '存档失败：$error';
    }
  }
}
