/// 桌面窗口适配层的**纯数据**部分：矩形、工作区与位置约束。
///
/// 把「窗口该放在哪」这类几何计算从 Win32 调用里拆出来，
/// 这样可以在 `dart test` 里直接验证，不用起窗口（对应 §12.1「可回放」的要求）。

/// 逻辑像素矩形（左上角 + 宽高）。
class WindowRect {
  const WindowRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  WindowRect copyWith({
    double? left,
    double? top,
    double? width,
    double? height,
  }) =>
      WindowRect(
        left: left ?? this.left,
        top: top ?? this.top,
        width: width ?? this.width,
        height: height ?? this.height,
      );

  @override
  String toString() => 'WindowRect($left, $top, ${width}x$height)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowRect &&
          other.left == left &&
          other.top == top &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// 显示器工作区（已排除任务栏）。
class WorkArea {
  const WorkArea({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  @override
  String toString() => 'WorkArea($left, $top, ${width}x$height)';
}

/// 把窗口约束进工作区（§6.3：移动目标限制在 work area，而不是整块屏幕）。
///
/// 规则：
///   - 窗口比工作区还大时，左上角对齐工作区左上角；
///   - 否则贴着四边时夹紧，保证整窗可见；
///   - [minVisible] 是「至少露出来多少像素」的兜底，用于多屏切换后抢救窗口。
WindowRect clampToWorkArea(
  WindowRect rect,
  WorkArea area, {
  double minVisible = 48,
}) {
  double width = rect.width;
  double height = rect.height;
  if (width > area.width) width = area.width;
  if (height > area.height) height = area.height;

  double left = rect.left;
  double top = rect.top;

  final double maxLeft = area.right - width;
  final double maxTop = area.bottom - height;

  if (left < area.left) left = area.left;
  if (left > maxLeft) left = maxLeft;
  if (top < area.top) top = area.top;
  if (top > maxTop) top = maxTop;

  // 极端情况：工作区比窗口还小（缩放到 200% 的窄屏），上面已经夹到左上角。
  if (!_visibleEnough(left, top, width, height, area, minVisible)) {
    left = area.left;
    top = area.top;
  }

  return WindowRect(left: left, top: top, width: width, height: height);
}

bool _visibleEnough(
  double left,
  double top,
  double width,
  double height,
  WorkArea area,
  double minVisible,
) {
  final double overlapX = _overlap(left, left + width, area.left, area.right);
  final double overlapY = _overlap(top, top + height, area.top, area.bottom);
  return overlapX >= minVisible && overlapY >= minVisible;
}

double _overlap(double a1, double a2, double b1, double b2) {
  final double start = a1 > b1 ? a1 : b1;
  final double end = a2 < b2 ? a2 : b2;
  final double value = end - start;
  return value > 0 ? value : 0;
}

/// 随机漫步的目标点：在当前工作区里挑一个落脚点。
///
/// 刻意保持为纯函数（外部注入随机值），方便测试与复盘。
WindowRect wanderTarget({
  required WindowRect current,
  required WorkArea area,
  required double random01,
  double margin = 24,
}) {
  final double usableWidth = area.width - current.width - margin * 2;
  final double minLeft = area.left + margin;
  final double left = usableWidth <= 0
      ? area.left
      : minLeft + usableWidth * random01.clamp(0.0, 1.0);
  return clampToWorkArea(
    current.copyWith(left: left),
    area,
    minVisible: 0,
  );
}
