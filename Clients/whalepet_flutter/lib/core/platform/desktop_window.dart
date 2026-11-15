import 'window_placement.dart';

/// 桌面窗口原生适配层的抽象（§6.3、§10.3）。
///
/// 约定：
///   - Dart 侧一律用**逻辑像素**；适配层内部负责乘/除 DPI 缩放；
///   - 「桌宠移动 = 移动窗口」，所以没有全屏透明画布；
///   - 位置更新由场景控制器节流到约 30fps，不在这里再兜底。
///
/// 实现见 `lib/platform/desktop_window/win32_window.dart`（Win32 FFI）。
abstract interface class DesktopWindowAdapter {
  /// 初始化（找到窗口句柄、应用初始样式）。重复调用应当幂等。
  Future<void> initialize();

  /// 当前显示器工作区（逻辑像素）。
  Future<WorkArea> workArea();

  /// 当前窗口矩形（逻辑像素）。
  Future<WindowRect> bounds();

  /// 设置窗口左上角（逻辑像素）。
  Future<void> setPosition(double left, double top);

  /// 设置窗口矩形（逻辑像素），用于展开/收起聊天面板。
  Future<void> setBounds(WindowRect rect);

  /// 置顶开关。
  Future<void> setAlwaysOnTop(bool enabled);

  /// 是否出现在任务栏/Alt+Tab（桌宠默认不出现）。
  Future<void> setSkipTaskbar(bool enabled);

  /// 鼠标穿透：开启后该窗口完全不接收鼠标事件（§6.3 提供可恢复入口）。
  Future<void> setClickThrough(bool enabled);

  /// 开始系统级拖拽（发 WM_NCLBUTTONDOWN/HTCAPTION），比在 Dart 里算位移更跟手。
  Future<void> startNativeDrag();

  /// 全局光标位置（逻辑像素，屏幕坐标系）；不支持的平台返回 null。
  ///
  /// 用途：窗口为了装下气泡/面板会比宠物本身大，透明区域需要「自动穿透」，
  /// 而穿透后 Flutter 收不到鼠标事件，只能靠这条全局坐标自己判断。
  ({double x, double y})? cursorPosition();

  /// 是否已经初始化成功。
  bool get isReady;

  /// 释放。
  Future<void> dispose();
}

/// 不支持的平台用的空实现：所有调用都是 no-op，便于在 Linux/macOS 上跑 UI 逻辑测试。
class NoopDesktopWindow implements DesktopWindowAdapter {
  const NoopDesktopWindow();

  @override
  bool get isReady => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<WorkArea> workArea() async =>
      const WorkArea(left: 0, top: 0, width: 1920, height: 1080);

  @override
  Future<WindowRect> bounds() async =>
      const WindowRect(left: 0, top: 0, width: 360, height: 460);

  @override
  Future<void> setPosition(double left, double top) async {}

  @override
  Future<void> setBounds(WindowRect rect) async {}

  @override
  Future<void> setAlwaysOnTop(bool enabled) async {}

  @override
  Future<void> setSkipTaskbar(bool enabled) async {}

  @override
  Future<void> setClickThrough(bool enabled) async {}

  @override
  Future<void> startNativeDrag() async {}

  @override
  ({double x, double y})? cursorPosition() => null;

  @override
  Future<void> dispose() async {}
}
