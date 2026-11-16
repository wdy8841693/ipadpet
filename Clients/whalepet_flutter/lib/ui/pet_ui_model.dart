import 'package:flutter/foundation.dart';

import '../core/agent/agent_gateway.dart';
import '../core/config/app_settings.dart';
import '../core/pet/pet_state.dart';
import '../core/pet/pet_vitals.dart';
import '../core/voice/voice_session_coordinator.dart';

/// 当前展开的面板（桌面是窗口内浮层，手机是场景上的浮层）。
enum PetPanel { none, chat, settings }

/// 聊天面板里的一条消息。
class ChatMessage {
  ChatMessage({required this.fromUser, required this.text, required this.at});

  final bool fromUser;
  final String text;
  final DateTime at;
}

/// 场景运行时对 UI 暴露的只读视图 + 动作集合。
///
/// 存在的意义（§6.3「移动端与桌面端分别实现场景控制器」）：
/// 面板/气泡/菜单这些**叶子组件**不该知道自己长在透明桌宠窗口里还是全屏手机场景里，
/// 它们只依赖这份接口即可被两个宿主复用。
///
/// 实现类：`PetRuntime`（桌面）、`MobilePetRuntime`（Android 全屏）。
abstract interface class PetViewModel implements Listenable {
  // -- 只读状态 -------------------------------------------------------------
  AppSettings get settings;

  PetVitals get vitals;

  PetState get petState;

  String get petName;

  String? get bubbleText;

  String? get lastError;

  PetPanel get panel;

  bool get menuOpen;

  bool get speechAvailable;

  bool get speaking;

  bool get isConnected;

  String get connectionLabel;

  String get voiceStateLabel;

  bool get voiceEnabled;

  /// 平台是否支持「开机自动启动」；不支持时设置面板不显示这一项。
  bool get autostartSupported;

  /// 当前唤醒词（设置面板展示用）。
  String get wakePhrase;

  AgentConnectionState get connectionState;

  VoiceSessionState get voiceState;

  /// 本机客户端 id（设置面板里展示，便于服务端日志对照）。
  String get runtimeClientId;

  List<ChatMessage> get chat;

  double get elapsedSeconds;

  /// 走路朝向（1 = 向右，-1 = 向左），决定立绘是否水平翻转。
  double get walkDirection;

  // -- 互动 ----------------------------------------------------------------
  void petHead();

  void feed();

  void play();

  void toggleSleep();

  Future<void> beginDrag();

  Future<void> endDrag();

  // -- 面板 & 菜单 ----------------------------------------------------------
  void openPanel(PetPanel panel);

  void closePanel();

  void toggleMenu();

  void closeMenu();

  // -- 文本 / 语音 ----------------------------------------------------------
  Future<void> sendText(String raw);

  void clearChat();

  Future<void> toggleVoice();

  Future<void> manualListen();

  Future<void> applySettings(AppSettings next, {String? token});

  Future<void> reconnect();

  // -- 持久化 --------------------------------------------------------------
  Future<void> persistNow();
}
