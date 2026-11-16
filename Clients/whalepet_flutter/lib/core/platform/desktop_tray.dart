/// 托盘动作（§10.3「处理置顶、无任务栏图标、托盘和开机启动」）。
///
/// Windows 端是真托盘图标（`Shell_NotifyIcon`），macOS 端是菜单栏状态项，
/// 两者语义一致；其它平台没有托盘，按「无托盘」处理。
enum DesktopTrayAction {
  /// 显示/隐藏桌宠窗口。
  toggleVisible,

  /// 开关语音唤醒（常驻 KWS）。
  toggleVoice,

  /// 打开设置面板。
  openSettings,

  /// 退出应用。
  quit,
}

/// 托盘适配层：把「用户在托盘里点了什么」翻译成动作，把「当前状态」同步回托盘。
///
/// 托盘是桌宠隐藏之后唯一的入口（窗口是 WS_EX_TOOLWINDOW，不在任务栏），
/// 所以「显示/隐藏」「语音开关」必须和 Dart 侧的状态保持一致。
abstract interface class DesktopTrayController {
  /// 托盘菜单触发的动作流。
  Stream<DesktopTrayAction> get actions;

  /// 同步托盘菜单状态：窗口是否可见、语音唤醒是否开启。
  ///
  /// Windows 端据此改菜单文案与勾选状态。
  Future<void> updateState({
    required bool visible,
    required bool voiceEnabled,
  });

  /// 退出应用（托盘「退出」）。
  ///
  /// 调用方负责先落盘；平台层负责把进程收干净（Windows 走 runner 的消息循环）。
  Future<void> quit();

  /// 释放。
  Future<void> dispose();
}

/// 没有托盘的平台（Android / Linux）用的空实现：所有调用都是 no-op。
class NoopDesktopTray implements DesktopTrayController {
  const NoopDesktopTray();

  @override
  Stream<DesktopTrayAction> get actions =>
      const Stream<DesktopTrayAction>.empty();

  @override
  Future<void> updateState({
    required bool visible,
    required bool voiceEnabled,
  }) async {}

  @override
  Future<void> quit() async {}

  @override
  Future<void> dispose() async {}
}
