import 'dart:ui' show Offset, Rect;

/// 桌宠窗口的固定布局（逻辑像素）。
///
/// 采用**固定窗口尺寸 + 自动鼠标穿透**，而不是「窗口跟着内容变大变小」：
///   - 尺寸稳定，动画与命中测试都好算；
///   - 透明区域由 `Win32DesktopWindow` 的 WS_EX_TRANSPARENT 动态放行点击（见 PetRuntime），
///     所以这块看不见的矩形不会挡住后面的软件。
class PetLayout {
  const PetLayout._();

  /// 窗口宽（逻辑像素）。
  static const double windowWidth = 380;

  /// 窗口高（逻辑像素）。
  static const double windowHeight = 560;

  /// 立绘尺寸。
  static const double petSize = 210;

  /// 立绘可点/可拖的区域（窗口内坐标）。
  static const Rect petRect = Rect.fromLTWH(
    (windowWidth - petSize) / 2,
    windowHeight - petSize - 6,
    petSize,
    petSize,
  );

  /// 面板（聊天 / 设置）区域。
  static const Rect panelRect = Rect.fromLTWH(12, 8, windowWidth - 24, 332);

  /// 右键菜单区域。
  static const Rect menuRect = Rect.fromLTWH(24, 56, 210, 282);

  /// 鼠标是否应当穿透到下层应用（桌宠透明窗口的命中判定）。
  ///
  /// 规则（§6.3）：
  /// - 面板或右键菜单**正在显示**时，整窗都要接收鼠标，否则面板/菜单里的
  ///   按钮和输入框会被穿透掉（这也是设置面板输入框点不动的根因之一）；
  /// - 面板/菜单都隐藏时，只有宠物立绘 [`petRect`] 接收鼠标，四周透明区
  ///   （含 [`menuRect`] / [`panelRect`] 所在范围）一律穿透到下层应用。
  ///
  /// `local` 是光标相对窗口左上角的坐标。把判定抽成纯函数，便于对
  /// 「宠物上方那块透明区在菜单隐藏时是否穿透」做回归测试。
  static bool shouldClickThrough(
    Offset local, {
    required bool panelVisible,
    required bool menuVisible,
  }) {
    if (panelVisible || menuVisible) return false;
    return !petRect.contains(local);
  }
}
