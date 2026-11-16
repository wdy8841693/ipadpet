import 'dart:async';
import 'dart:math';
import 'dart:ui' show Offset, Size;

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
import '../../core/storage/pet_save.dart';
import '../../core/storage/pet_save_store.dart';
import '../../core/voice/speech_output.dart';
import '../../core/voice/speech_queue.dart';
import '../../core/voice/voice_engine.dart';
import '../../core/voice/voice_session_coordinator.dart';
import '../pet_ui_model.dart';

/// Android 全屏场景的运行时（§6.3「移动端与桌面端分别实现场景控制器」）。
///
/// 与桌面版 [PetRuntime] 的差别只在**移动方式**：
/// - 桌面是「窗口就是宠物」，走路=移动原生窗口；
/// - 这里是「屏幕坐标系内的场景」，走路=在场景里改坐标，宠物始终留在 App 内。
///
/// 其余全部复用：同一套 `core/`（数值、行为、台词、语音协调器、Agent 协议、存档）。
class MobilePetRuntime extends ChangeNotifier implements PetViewModel {
  MobilePetRuntime({
    required this.paths,
    required this.speech,
    required this.voiceEngine,
    TokenStorage? tokenStorage,
    String clientIdPrefix = 'android',
    Random? random,
  })  : _tokenStorage = tokenStorage ?? TokenStore(file: paths.tokenFile),
        _clientIdPrefix = clientIdPrefix,
        _random = random ?? Random() {
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
        await _gateway?.cancel(requestId);
      },
    );
    _coordinatorSubscription = coordinator.events.listen(_onCoordinatorEvent);
    _voiceStateSubscription = coordinator.states.listen((VoiceSessionState state) {
      _voiceState = state;
      notifyListeners();
    });
  }

  final AppPaths paths;
  final SpeechOutputAdapter speech;
  final VoiceEngineAdapter voiceEngine;
  final TokenStorage _tokenStorage;
  final String _clientIdPrefix;
  final Random _random;

  static const int _tickMs = 33;
  static const double _walkSpeed = 34;
  static const double _swimSpeed = 62;
  static const double _floorRatio = 0.84;

  late final PetBehavior _behavior;
  late final Dialogue _dialogue;

  /// 语音状态机（UI 只读状态与事件，不反向改状态）。
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
  double _behaviorTimer = 0;
  double _bubbleRemaining = 0;
  double _saveTimer = 0;
  double _elapsed = 0;

  String? _bubbleText;
  String? _lastError;
  bool _announcedConnection = false;

  PetPanel _panel = PetPanel.none;
  bool _menuOpen = false;
  bool _started = false;
  bool _servicesStarted = false;
  bool _disposed = false;

  Timer? _ticker;

  Size _sceneSize = const Size(360, 640);
  bool _sceneReady = false;
  Offset _pos = Offset.zero;
  Offset? _target;

  // -- 只读状态 -------------------------------------------------------------

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

  /// Android 端暂不接开机自启（要写开机广播/AppWidget，收益低于成本）。
  @override
  bool get autostartSupported => false;

  @override
  String get runtimeClientId => _clientId;

  @override
  List<ChatMessage> get chat => List<ChatMessage>.unmodifiable(_chat);

  @override
  double get elapsedSeconds => _elapsed;

  @override
  double get walkDirection => _walkDirection;

  @override
  bool get isConnected => _connectionState == AgentConnectionState.connected;

  /// 宠物脚底所在的场景坐标（左上角原点，单位逻辑像素）。
  Offset get petPosition => _pos;

  /// 场景尺寸（由界面在布局时回填）。
  Size get sceneSize => _sceneSize;

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

  /// 快速启动：读配置 → 读存档 → 读客户端 id。必须先跑完再 runApp。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await paths.ensureCreated();
    _settingsStore = SettingsStore(file: paths.settingsFile);
    _settings = await _settingsStore!.load();
    coordinator.setConfig(_voiceConfigFromSettings(_settings, revision: 1));
    await _loadPet();
    await _loadIdentity();
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
    _ticker = Timer.periodic(const Duration(milliseconds: _tickMs), (_) => _onTick());
    notifyListeners();
  }

  VoiceEngineConfig _voiceConfigFromSettings(AppSettings settings,
          {required int revision}) =>
      VoiceEngineConfig(
        wakePhrase: settings.wakePhrase,
        wakeAliases: settings.wakeAliases,
        wakeAck: settings.wakeAck,
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
    _vitals.settleOffline(DateTime.now().toUtc().difference(save.lastTickUtc));
  }

  Future<void> _loadIdentity() async {
    final ClientIdStore idStore = ClientIdStore(file: paths.clientIdFile);
    String? id = await idStore.read();
    if (id == null) {
      id = newClientId(prefix: _clientIdPrefix, random: _random);
      await idStore.write(id);
    }
    _clientId = id;
    _token = await _tokenStorage.read();
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
      subscriptionsAnnouncements: _settings.subscriptionsAnnouncements,
    );
    _gateway = gateway;
    _eventSubscription = gateway.events.listen(_onAgentEvent);
    _stateSubscription = gateway.states.listen(_setConnectionState);
    unawaited(gateway.connect().catchError((Object _) {}));
  }

  /// 界面布局变化时回填场景尺寸（首次会把握宠物放到海底地面中间）。
  void updateSceneSize(Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final bool first = !_sceneReady;
    _sceneSize = size;
    _sceneReady = true;
    if (first) {
      _pos = Offset(size.width / 2, _floorY);
    } else {
      _pos = Offset(_pos.dx.clamp(40.0, size.width - 40.0),
          _pos.dy.clamp(0.0, size.height - 40.0));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    unawaited(_eventSubscription?.cancel());
    unawaited(_stateSubscription?.cancel());
    unawaited(_coordinatorSubscription?.cancel());
    unawaited(_voiceStateSubscription?.cancel());
    unawaited(coordinator.dispose());
    unawaited(_gateway?.dispose());
    unawaited(speech.dispose());
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
    if (_disposed || !_sceneReady) return;
    const double dt = _tickMs / 1000.0;
    _elapsed += dt;

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
    _saveTimer += dt;
    if (_saveTimer >= 15) {
      _saveTimer = 0;
      unawaited(persistNow());
    }
    notifyListeners();
  }

  double get _floorY => _sceneSize.height * _floorRatio;

  void _moveTick(double dt) {
    switch (_petState) {
      case PetState.walk:
        double x = _pos.dx + _walkDirection * _walkSpeed * dt;
        const double margin = 46;
        if (x < margin) {
          x = margin;
          _walkDirection = 1;
        } else if (x > _sceneSize.width - margin) {
          x = _sceneSize.width - margin;
          _walkDirection = -1;
        }
        _pos = Offset(x, _lerpTo(_pos.dy, _floorY, dt * 2));
        break;
      case PetState.swim:
        _target ??= _randomSwimTarget();
        final Offset target = _target!;
        final Offset delta = target - _pos;
        final double distance = delta.distance;
        if (distance < 6) {
          _target = _randomSwimTarget();
        } else {
          final Offset step = delta / distance * (_swimSpeed * dt);
          _pos = _clampToScene(_pos + step);
        }
        if ((target.dx - _pos.dx).abs() > 4) {
          _walkDirection = target.dx > _pos.dx ? 1 : -1;
        }
        break;
      case PetState.idle:
      case PetState.sleep:
      case PetState.eat:
      case PetState.happy:
      case PetState.play:
        _target = null;
        _pos = Offset(_pos.dx, _lerpTo(_pos.dy, _floorY, dt * 1.6));
        break;
      default:
        break;
    }
  }

  Offset _randomSwimTarget() {
    final double width = max(_sceneSize.width, 1);
    final double height = max(_sceneSize.height, 1);
    return Offset(
      60 + _random.nextDouble() * max(width - 120, 1),
      height * 0.30 + _random.nextDouble() * height * 0.34,
    );
  }

  Offset _clampToScene(Offset value) {
    final double maxX = max(_sceneSize.width - 46, 46);
    final double maxY = max(_sceneSize.height - 60, 60);
    return Offset(value.dx.clamp(46.0, maxX), value.dy.clamp(60.0, maxY));
  }

  double _lerpTo(double from, double to, double k) {
    final double t = k.clamp(0.0, 1.0);
    return from + (to - from) * t;
  }

  void _maybeSwitchAutonomous() {
    if (!_sceneReady) return;
    if (_petState.isBusy || _panel != PetPanel.none || _menuOpen || _dragging) return;
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
    if (next == PetState.swim) _target = null;
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
    }
  }

  void _setState(PetState next) {
    if (_petState == next) return;
    _petState = next;
    if (next == PetState.swim) _target = null;
    notifyListeners();
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
    if (!_vitals.feed(sleeping: false)) {
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
    _vitals.play(sleeping: false);
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
    notifyListeners();
  }

  /// 拖拽过程中由场景调用：把宠物脚底挪到 [feet]。
  void dragTo(Offset feet) {
    if (!_dragging) return;
    _pos = _clampToScene(feet);
    notifyListeners();
  }

  @override
  Future<void> endDrag() async {
    if (!_dragging) return;
    _dragging = false;
    _transientRemaining = 0.8;
    _setState(PetState.happy);
    notifyListeners();
  }

  // -- 面板 & 菜单 ----------------------------------------------------------

  @override
  void openPanel(PetPanel panel) {
    _panel = panel;
    _menuOpen = false;
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
    notifyListeners();
  }

  @override
  void closeMenu() {
    if (!_menuOpen) return;
    _menuOpen = false;
    notifyListeners();
  }

  // -- 文本 / 语音 ----------------------------------------------------------

  @override
  Future<void> sendText(String raw) => coordinator.submitText(raw);

  @override
  void clearChat() {
    _chat.clear();
    notifyListeners();
  }

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
    notifyListeners();
  }

  @override
  Future<void> manualListen() async {
    closeMenu();
    closePanel();
    await coordinator.manualListen();
  }

  /// 取消当前这一轮（停止本地等待与播报）。
  Future<void> cancelVoice() async {
    closeMenu();
    await coordinator.cancel();
  }

  @override
  Future<void> applySettings(AppSettings next, {String? token}) async {
    final bool serverChanged =
        next.serverUrl.trim() != _settings.serverUrl.trim();
    final bool voiceChanged = next.wakePhrase != _settings.wakePhrase ||
        next.wakeAck != _settings.wakeAck ||
        next.wakeAliases.join('|') != _settings.wakeAliases.join('|');
    _settings = next;
    await _settingsStore?.save(_settings);

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
    if (serverChanged || token != null) {
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

  @override
  Future<void> reconnect() => _restartGateway();

  /// App 进入后台：停采集，避免"偷偷听"（§10.1）。
  ///
  /// 用 suspend 而不是 disable：语音开关本身没被用户关掉，
  /// 回到前台应该按原设置恢复，也不该冒一句「语音关掉啦」。
  Future<void> handleBackground() async {
    await coordinator.suspend();
    await persistNow();
  }

  /// 回到前台：按用户设置恢复语音。
  Future<void> handleForeground() async {
    await coordinator.resume();
  }

  // -- Agent 事件 ----------------------------------------------------------

  void _setConnectionState(AgentConnectionState next) {
    if (_connectionState == next) return;
    _connectionState = next;
    if (next == AgentConnectionState.failed) {
      _lastError = '连接失败：检查地址与令牌（右上角 ⚙️ 设置）';
    }
    notifyListeners();
  }

  void _onAgentEvent(AgentServerEvent event) {
    coordinator.onAgentEvent(event);
    if (event is AgentReadyEvent && !_announcedConnection) {
      _announcedConnection = true;
      _say('连上 DSH 啦，点麦克风跟我说话～', seconds: 5);
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
    } catch (error) {
      _lastError = '存档失败：$error';
    }
  }
}
