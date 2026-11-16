import 'dart:async';
import 'dart:io';
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
import '../../core/platform/autostart.dart';
import '../../core/platform/desktop_tray.dart';
import '../../core/platform/desktop_window.dart';
import '../../core/platform/window_placement.dart';
import '../../core/storage/pet_save.dart';
import '../../core/storage/pet_save_store.dart';
import '../../core/voice/speech_output.dart';
import '../../core/voice/speech_queue.dart';
import '../../core/voice/voice_engine.dart';
import '../../core/voice/voice_session_coordinator.dart';
import '../pet_ui_model.dart';
import 'pet_layout.dart';

export '../pet_ui_model.dart' show ChatMessage, PetPanel;

/// 桌宠运行时：宠物数值、窗口、网络与语音的唯一装配点。
///
/// 架构边界（§7.1）：回答、任务事件、播报队列全部由 [VoiceSessionCoordinator]
/// 统一持有；本类只负责把它们翻译成 UI 状态，以及管理窗口/存档/连接生命周期。
class PetRuntime extends ChangeNotifier implements PetViewModel {
  PetRuntime({
    required this.paths,
    required this.window,
    required this.speech,
    required this.voiceEngine,
    TokenStorage? tokenStorage,
    Random? random,
    DesktopTrayController? tray,
    AutostartController? autostart,
  })  : _tokenStorage = tokenStorage ?? TokenStore(file: paths.tokenFile),
        _random = random ?? Random(),
        _tray = tray,
        _autostart = autostart {
    _behavior = PetBehavior(random: _random);
    _dialogue = Dialogue(random: _random);
    coordinator = VoiceSessionCoordinator(
      engine: voiceEngine,
      speech: speech,
      queue: SpeechQueue(),
      config: const VoiceEngineConfig(),
      speakEnabled: () => _settings.speakResponses && _speechAvailable,
      sendCommand: ({
        required String requestId,
        required String text,
        required String source,
      }) async {
        final WebSocketAgentGateway? gateway = _gateway;
        if (gateway == null) throw StateError('还没连上服务端');
        await gateway.sendCommand(
          requestId: requestId,
          text: text,
          source: source,
        );
      },
      cancelCommand: (String requestId) async {
        final WebSocketAgentGateway? gateway = _gateway;
        if (gateway == null) return;
        await gateway.cancel(requestId);
      },
    );
    _coordinatorSubscription = coordinator.events.listen(_onCoordinatorEvent);
    _voiceStateSubscription = coordinator.states.listen((VoiceSessionState state) {
      _voiceState = state;
      notifyListeners();
    });
    // 显示器变了就重新约束窗口位置（§10.2）：插拔外接显示器后桌宠不能
    // 留在已经不存在的屏幕上。
    if (window is DisplayChangeAware) {
      _displaySubscription = (window as DisplayChangeAware).displayChanges
          .listen((_) => unawaited(_refreshWorkArea()));
    }
    // 托盘（Windows 才有）：托盘菜单与右键菜单走同一套行为，避免两处逻辑分叉。
    final DesktopTrayController? trayController = _tray;
    if (trayController != null) {
      _traySubscription = trayController.actions.listen((DesktopTrayAction action) {
        unawaited(_onTrayAction(action));
      });
    }
  }

  final AppPaths paths;
  final DesktopWindowAdapter window;
  final SpeechOutputAdapter speech;
  final VoiceEngineAdapter voiceEngine;

  /// 托盘适配层（Windows 有；其它平台为 null）。
  final DesktopTrayController? _tray;

  /// 开机自启适配层（Windows 有；其它平台为 null）。
  final AutostartController? _autostart;
  final TokenStorage _tokenStorage;
  final Random _random;

  static const int _tickMs = 33;
  static const double _walkSpeed = 34;

  late final PetBehavior _behavior;
  late final Dialogue _dialogue;

  /// 语音状态机（UI 只读它的状态与事件，不反向改状态）。
  late final VoiceSessionCoordinator coordinator;

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
  StreamSubscription<CoordinatorEvent>? _coordinatorSubscription;
  StreamSubscription<VoiceSessionState>? _voiceStateSubscription;
  StreamSubscription<void>? _displaySubscription;
  StreamSubscription<DesktopTrayAction>? _traySubscription;
  AgentConnectionState _connectionState = AgentConnectionState.disconnected;
  VoiceSessionState _voiceState = VoiceSessionState.disabled;
  String? _token;
  String _clientId = '';

  final List<ChatMessage> _chat = <ChatMessage>[];
  bool _speechAvailable = false;

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
  bool _announcedConnection = false;

  PetPanel _panel = PetPanel.none;
  bool _menuOpen = false;
  bool _clickThrough = false;
  bool _windowVisible = true;
  bool _windowReady = false;
  bool _started = false;
  bool _servicesStarted = false;
  bool _disposed = false;

  Timer? _ticker;
  WindowRect _bounds = const WindowRect(
    left: 0,
    top: 0,
    width: PetLayout.windowWidth,
    height: PetLayout.windowHeight,
  );
  WorkArea _area = const WorkArea(left: 0, top: 0, width: 1920, height: 1080);

  // -- 只读状态（UI 读这些）--------------------------------------------------

  @override
  AppSettings get settings => _settings;
  @override
  PetVitals get vitals => _vitals;
  @override
  PetState get petState => _petState;
  @override
  String get petName => _petName;
  @override
  String? get bubbleText => _bubbleText;
  @override
  String? get lastError => _lastError;
  @override
  PetPanel get panel => _panel;
  @override
  bool get menuOpen => _menuOpen;
  bool get clickThrough => _clickThrough;
  @override
  bool get speechAvailable => _speechAvailable;
  @override
  bool get speaking => coordinator.isSpeaking;
  @override
  AgentConnectionState get connectionState => _connectionState;
  @override
  String get wakePhrase => coordinator.config.wakePhrase;
  @override
  VoiceSessionState get voiceState => _voiceState;
  @override
  bool get voiceEnabled => _settings.voiceWakeEnabled;

  /// 平台是否支持开机自启（Windows 有；其它平台没有）。
  @override
  bool get autostartSupported => _autostart != null;

  /// 桌宠窗口当前是否可见（托盘可以把它藏起来）。
  bool get windowVisible => _windowVisible;

  /// 本机客户端 id（设置面板里展示，便于服务端日志对照）。
  @override
  String get runtimeClientId => _clientId;
  @override
  List<ChatMessage> get chat => List<ChatMessage>.unmodifiable(_chat);
  @override
  double get elapsedSeconds => _elapsed;

  /// 走路朝向（1 = 向右，-1 = 向左），决定立绘是否水平翻转。
  @override
  double get walkDirection => _walkDirection;
  @override
  bool get isConnected => _connectionState == AgentConnectionState.connected;

  @override
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

  /// 语音状态说明（设置面板/菜单里显示）。
  @override
  String get voiceStateLabel {
    switch (_voiceState) {
      case VoiceSessionState.disabled:
        return '语音关闭';
      case VoiceSessionState.preparing:
        return '语音启动中…';
      case VoiceSessionState.waitingWake:
        return '等待唤醒（${coordinator.config.wakePhrase}）';
      case VoiceSessionState.listening:
        return '正在聆听';
      case VoiceSessionState.recognizing:
        return '识别中';
      case VoiceSessionState.thinking:
        return '处理中';
      case VoiceSessionState.speaking:
        return '播报中';
      case VoiceSessionState.error:
        return '语音不可用';
    }
  }

  // -- 生命周期 -------------------------------------------------------------

  /// 快速启动：读配置 → 读存档 → 建窗口。必须先跑完再 runApp。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await paths.ensureCreated();
    _settingsStore = SettingsStore(file: paths.settingsFile);
    _settings = await _settingsStore!.load();
    coordinator.setConfig(_voiceConfigFromSettings(_settings, revision: 1));
    await _loadPet();
    await _loadIdentity();
    await _initWindow();
    notifyListeners();
  }

  /// 慢启动：播报引擎 → 连接 → 语音 → 帧循环。runApp 之后再跑。
  Future<void> startServices() async {
    if (_servicesStarted) return;
    _servicesStarted = true;
    await _initSpeech();
    await _connectIfConfigured();
    if (_settings.voiceWakeEnabled) {
      await coordinator.enable();
    }
    // 托盘菜单状态（窗口可见性、语音开关）要与真实状态一致。
    await _syncTrayState();
    if (_settings.autostartEnabled) {
      // 便携包换了目录后，启动项里记的还是旧路径，这里顺手刷新一次。
      await _applyAutostart(true);
    }
    _ticker = Timer.periodic(const Duration(milliseconds: _tickMs), (_) => _onTick());
    notifyListeners();
  }

  VoiceEngineConfig _voiceConfigFromSettings(AppSettings settings,
          {required int revision}) =>
      VoiceEngineConfig(
        wakePhrase: settings.wakePhrase,
        wakeAliases: settings.wakeAliases,
        wakeAck: settings.wakeAck,
        oneShotCommand: settings.oneShotCommandEnabled,
        revision: revision,
      );

  Future<void> _loadPet() async {
    _saveStore = PetSaveStore(directory: paths.saveDirectory);
    final PetSave save = await _saveStore!.load();
    _vitals = save.vitals;
    _petName = save.petName;
    _totalFeeds = save.totalFeeds;
    _totalPets = save.totalPets;
    _bornAtUtc = save.bornAtUtc;
    _vitals.settleOffline(
      DateTime.now().toUtc().difference(save.lastTickUtc),
    );
  }

  Future<void> _loadIdentity() async {
    final ClientIdStore idStore = ClientIdStore(file: paths.clientIdFile);
    String? id = await idStore.read();
    if (id == null) {
      id = newClientId(prefix: Platform.operatingSystem, random: _random);
      await idStore.write(id);
    }
    _clientId = id;
    _token = await _tokenStorage.read();
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

  /// 显示器/工作区变了：重读工作区并把窗口夹回可见范围。
  Future<void> _refreshWorkArea() async {
    if (_disposed || !_windowReady) return;
    try {
      final WorkArea area = await window.workArea();
      _area = area;
      final WindowRect clamped = clampToWorkArea(_bounds, area);
      if (clamped.left != _bounds.left || clamped.top != _bounds.top) {
        _bounds = clamped;
        await window.setPosition(_bounds.left, _bounds.top);
      }
    } catch (_) {
      // 读不到工作区就保持原样，下一次变化时再试。
    }
  }

  WindowRect _initialBounds() {
    final double defaultLeft =
        _area.left + (_area.width - PetLayout.windowWidth) / 2;
    final double defaultTop = _area.bottom - PetLayout.windowHeight - 8;
    return clampToWorkArea(
      WindowRect(
        left: _settings.windowX ?? defaultLeft,
        top: _settings.windowY ?? defaultTop,
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
      deviceKind: Platform.operatingSystem,
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
    unawaited(_coordinatorSubscription?.cancel());
    unawaited(_voiceStateSubscription?.cancel());
    unawaited(_displaySubscription?.cancel());
    unawaited(_traySubscription?.cancel());
    unawaited(_tray?.dispose());
    unawaited(coordinator.dispose());
    unawaited(_gateway?.dispose());
    unawaited(speech.dispose());
    unawaited(window.dispose());
    super.dispose();
  }

  // -- 协调器 → UI ----------------------------------------------------------

  void _onCoordinatorEvent(CoordinatorEvent event) {
    if (_disposed) return;
    switch (event) {
      case CoordinatorBubbleEvent():
        _say(event.text, seconds: event.seconds);
      case CoordinatorTranscriptEvent():
        if (event.text.isEmpty) {
          if (_bubbleText != null && _bubbleText!.startsWith('听到：')) {
            _bubbleText = null;
          }
        } else {
          _say('听到：${event.text}', seconds: 2);
        }
      case CoordinatorChatEvent():
        _chat.add(ChatMessage(
          fromUser: event.fromUser,
          text: event.text,
          at: DateTime.now(),
        ));
      case CoordinatorPetStateEvent():
        _transientRemaining = 0;
        _setState(event.state);
      case CoordinatorErrorEvent():
        _lastError = event.message;
        _say(event.message, seconds: 8);
    }
    notifyListeners();
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
      final WindowRect next =
          _bounds.copyWith(left: _bounds.left + _walkDirection * _walkSpeed * dt);
      final WindowRect clamped = clampToWorkArea(next, _area, minVisible: 0);
      if (clamped.left != next.left) _walkDirection = -_walkDirection;
      if (clamped.left != _bounds.left) {
        _bounds = clamped;
        unawaited(window.setPosition(_bounds.left, _bounds.top));
      }
    } else if (_petState == PetState.swim) {
      _swimPhase += dt;
      final WindowRect clamped = clampToWorkArea(
        _bounds.copyWith(top: _swimBaseTop + sin(_swimPhase * 1.1) * 10),
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
    if (next == PetState.sleep && _vitals.energy > 55) return;
    if (_petState == PetState.sleep && next != PetState.sleep) {
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

  // -- 鼠标穿透 -------------------------------------------------------------

  Future<void> _updateClickThrough() async {
    if (!_windowReady) return;
    final ({double x, double y})? cursor = window.cursorPosition();
    if (cursor == null) return;
    _bounds = await window.bounds();
    final Offset local = Offset(cursor.x - _bounds.left, cursor.y - _bounds.top);
    final bool interactive = PetLayout.petRect.contains(local) ||
        (_panel != PetPanel.none && PetLayout.panelRect.contains(local)) ||
        (_menuOpen && PetLayout.menuRect.contains(local));
    final bool want = !interactive;
    if (want == _clickThrough) return;
    _clickThrough = want;
    await window.setClickThrough(want);
  }

  // -- 互动 ----------------------------------------------------------------

  @override
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

  @override
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

  @override
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

  @override
  void toggleSleep() {
    if (_petState == PetState.sleep) {
      _setState(PetState.idle);
      _say('唔……我醒了', seconds: 3);
    } else if (!_petState.isBusy) {
      _setState(PetState.sleep);
      _say('那我先睡一会儿～', seconds: 3);
    }
  }

  @override
  Future<void> beginDrag() async {
    _dragging = true;
    _transientRemaining = 0;
    _setState(PetState.drag);
    await window.startNativeDrag();
  }

  @override
  Future<void> endDrag() async {
    _dragging = false;
    _transientRemaining = 1.0;
    _bounds = clampToWorkArea(await window.bounds(), _area, minVisible: 0);
    await window.setPosition(_bounds.left, _bounds.top);
    notifyListeners();
  }

  // -- 面板 & 菜单 ----------------------------------------------------------

  @override
  void openPanel(PetPanel panel) {
    _panel = panel;
    _menuOpen = false;
    if (_clickThrough) {
      _clickThrough = false;
      unawaited(window.setClickThrough(false));
    }
    notifyListeners();
  }

  @override
  void closePanel() {
    if (_panel == PetPanel.none) return;
    _panel = PetPanel.none;
    notifyListeners();
  }

  @override
  void toggleMenu() {
    _menuOpen = !_menuOpen;
    if (_clickThrough) {
      _clickThrough = false;
      unawaited(window.setClickThrough(false));
    }
    notifyListeners();
  }

  @override
  void closeMenu() {
    if (!_menuOpen) return;
    _menuOpen = false;
    notifyListeners();
  }

  // -- 文本 / 语音命令 ------------------------------------------------------

  @override
  Future<void> sendText(String raw) => coordinator.submitText(raw);

  @override
  void clearChat() {
    _chat.clear();
    notifyListeners();
  }

  /// 打开/关闭语音唤醒。
  @override
  Future<void> toggleVoice() async {
    final bool next = !_settings.voiceWakeEnabled;
    final AppSettings updated = _settings.copyWith(voiceWakeEnabled: next);
    _settings = updated;
    await _settingsStore?.save(updated);
    if (next) {
      await coordinator.enable();
    } else {
      await coordinator.disable();
    }
    await _syncTrayState();
    notifyListeners();
  }

  // -- 托盘 ------------------------------------------------------------------

  /// 托盘菜单动作（§10.3）。与右键菜单共用行为，避免两套逻辑分叉。
  Future<void> _onTrayAction(DesktopTrayAction action) async {
    switch (action) {
      case DesktopTrayAction.toggleVisible:
        await _toggleWindowVisible();
      case DesktopTrayAction.toggleVoice:
        await toggleVoice();
      case DesktopTrayAction.openSettings:
        openPanel(PetPanel.settings);
      case DesktopTrayAction.quit:
        await _quitApp();
    }
    await _syncTrayState();
  }

  /// 显示/隐藏桌宠窗口。
  ///
  /// 桌宠窗口是 `WS_EX_TOOLWINDOW`，不在任务栏；隐藏之后只能靠托盘找回来，
  /// 所以显隐必须走原生层（Dart 只发意图）。
  Future<void> _toggleWindowVisible() async {
    // 注意这里用 Object 而不是 DesktopWindowAdapter：
    // WindowVisibilityAware 是与 DesktopWindowAdapter **无关**的接口，
    // Dart 的类型提升要求「被提升的类型是声明类型的子类型」，
    // 直接按 DesktopWindowAdapter 声明的话 is 检查后无法提升，编译不过。
    final Object adapter = window;
    if (adapter is! WindowVisibilityAware) return;
    final WindowVisibilityAware visibility = adapter;
    await visibility.setVisible(!visibility.isVisible);
    _windowVisible = visibility.isVisible;
    notifyListeners();
  }

  /// 把当前状态同步给托盘菜单（窗口可见性、语音唤醒开关）。
  Future<void> _syncTrayState() async {
    final DesktopTrayController? tray = _tray;
    if (tray == null) return;
    try {
      await tray.updateState(
        visible: _windowVisible,
        voiceEnabled: _settings.voiceWakeEnabled,
      );
    } catch (_) {
      // 托盘不可用不影响主流程。
    }
  }

  /// 退出：先落盘，再让平台层结束进程。
  Future<void> _quitApp() async {
    await persistNow();
    final DesktopTrayController? tray = _tray;
    if (tray == null) {
      exit(0);
    }
    await tray.quit();
    // 兜底：平台层没把进程收掉的话，1.5 秒后自己退。
    unawaited(Future<void>.delayed(const Duration(milliseconds: 1500), () {
      exit(0);
    }));
  }

  /// 手动点击说话（跳过唤醒词）。
  @override
  Future<void> manualListen() async {
    closeMenu();
    closePanel();
    await coordinator.manualListen();
  }

  /// 取消当前这一轮。
  Future<void> cancelVoice() async {
    closeMenu();
    await coordinator.cancel();
  }

  /// 保存设置并（必要时）重连 / 重建唤醒语法。
  @override
  Future<void> applySettings(AppSettings next, {String? token}) async {
    final bool serverChanged =
        next.serverUrl.trim() != _settings.serverUrl.trim();
    final bool voiceChanged = next.wakePhrase != _settings.wakePhrase ||
        next.wakeAck != _settings.wakeAck ||
        next.oneShotCommandEnabled != _settings.oneShotCommandEnabled ||
        next.wakeAliases.join('|') != _settings.wakeAliases.join('|');
    final bool autostartChanged =
        next.autostartEnabled != _settings.autostartEnabled;
    _settings = next;
    await _settingsStore?.save(_settings);
    await window.setAlwaysOnTop(next.alwaysOnTop);
    if (token != null) {
      await _tokenStorage.write(token);
      final String trimmed = token.trim();
      _token = trimmed.isEmpty ? null : trimmed;
    }
    if (voiceChanged) {
      coordinator.setConfig(_voiceConfigFromSettings(
        next,
        revision: coordinator.config.revision + 1,
      ));
    }
    if (next.voiceWakeEnabled && !coordinator.enabled) {
      await coordinator.enable();
    } else if (!next.voiceWakeEnabled && coordinator.enabled) {
      await coordinator.disable();
    }
    if (autostartChanged) {
      await _applyAutostart(next.autostartEnabled);
    }
    if (serverChanged || token != null) {
      await _restartGateway();
    }
    await _syncTrayState();
    notifyListeners();
  }

  /// 写系统开机自启；失败时回滚设置并给出原因。
  Future<void> _applyAutostart(bool enabled) async {
    final AutostartController? autostart = _autostart;
    if (autostart == null) return;
    bool ok = false;
    try {
      ok = await autostart.setEnabled(enabled);
    } catch (error) {
      _lastError = '开机自启设置失败：$error';
    }
    if (ok) return;
    _lastError ??= '开机自启设置失败（系统拒绝了写入）';
    _settings = _settings.copyWith(autostartEnabled: !enabled);
    await _settingsStore?.save(_settings);
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

  @override
  Future<void> reconnect() => _restartGateway();

  // -- Agent 事件 ----------------------------------------------------------

  void _setConnectionState(AgentConnectionState next) {
    if (_connectionState == next) return;
    _connectionState = next;
    if (next == AgentConnectionState.failed) {
      _lastError = '连接失败：检查地址与令牌（右键 → 设置）';
    }
    notifyListeners();
  }

  /// 服务端事件一律转给协调器；本类只额外处理「连上了」的一次性提示。
  void _onAgentEvent(AgentServerEvent event) {
    coordinator.onAgentEvent(event);
    if (event is AgentReadyEvent && !_announcedConnection) {
      _announcedConnection = true;
      _say('连上 DSH 啦，双击我说话～', seconds: 5);
    }
  }

  // -- 持久化 --------------------------------------------------------------

  void _say(String text, {double seconds = 6}) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _bubbleText = trimmed;
    _bubbleRemaining = seconds;
    notifyListeners();
  }

  @override
  Future<void> persistNow() async {
    final PetSaveStore? store = _saveStore;
    if (store == null) return;
    try {
      await store.save(PetSave(
        vitals: _vitals,
        lastTickUtc: DateTime.now().toUtc(),
        petName: _petName,
        totalFeeds: _totalFeeds,
        totalPets: _totalPets,
        bornAtUtc: _bornAtUtc,
      ));
      await _settingsStore?.save(_settings.copyWith(
        windowX: _bounds.left,
        windowY: _bounds.top,
      ));
    } catch (error) {
      _lastError = '存档失败：$error';
    }
  }
}
