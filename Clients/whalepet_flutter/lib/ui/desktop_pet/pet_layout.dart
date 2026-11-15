import 'dart:ui' show Rect;

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
  static const Rect menuRect = Rect.fromLTWH(24, 92, 210, 246);
}
