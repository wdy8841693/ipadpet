import 'package:test/test.dart';
import 'package:whalepet_flutter/core/platform/window_placement.dart';

void main() {
  const WorkArea area = WorkArea(left: 0, top: 0, width: 1920, height: 1040);

  group('clampToWorkArea', () {
    test('完全在工作区内时不动', () {
      const WindowRect rect = WindowRect(left: 100, top: 100, width: 380, height: 560);
      expect(clampToWorkArea(rect, area), rect);
    });

    test('超出右边界时贴右边', () {
      const WindowRect rect = WindowRect(left: 1800, top: 100, width: 380, height: 560);
      final WindowRect clamped = clampToWorkArea(rect, area);
      expect(clamped.right, area.right);
      expect(clamped.left, 1920 - 380);
    });

    test('超出下边界时贴底', () {
      const WindowRect rect = WindowRect(left: 100, top: 900, width: 380, height: 560);
      final WindowRect clamped = clampToWorkArea(rect, area);
      expect(clamped.bottom, area.bottom);
    });

    test('负坐标被夹回工作区', () {
      const WindowRect rect = WindowRect(left: -200, top: -50, width: 380, height: 560);
      final WindowRect clamped = clampToWorkArea(rect, area);
      expect(clamped.left, 0);
      expect(clamped.top, 0);
    });

    test('窗口比工作区还大时缩到工作区大小并贴左上', () {
      const WorkArea small = WorkArea(left: 100, top: 50, width: 300, height: 200);
      const WindowRect rect = WindowRect(left: 0, top: 0, width: 380, height: 560);
      final WindowRect clamped = clampToWorkArea(rect, small);
      expect(clamped.width, 300);
      expect(clamped.height, 200);
      expect(clamped.left, 100);
      expect(clamped.top, 50);
    });

    test('多屏切换后窗口完全在屏幕外会被拉回左上', () {
      // 第二块屏在左边（负坐标），窗口留在了那块屏上。
      const WorkArea primary = WorkArea(left: 0, top: 0, width: 1920, height: 1040);
      const WindowRect rect = WindowRect(left: -1500, top: 200, width: 380, height: 560);
      final WindowRect clamped =
          clampToWorkArea(rect, primary, minVisible: 48);
      expect(clamped.left, 0);
      expect(clamped.top, 200);
    });
  });

  group('wanderTarget', () {
    test('目标点始终在工作区内', () {
      const WindowRect current =
          WindowRect(left: 700, top: 400, width: 380, height: 560);
      for (final double random in <double>[0, 0.25, 0.5, 0.99, 1]) {
        final WindowRect target =
            wanderTarget(current: current, area: area, random01: random);
        expect(target.left, greaterThanOrEqualTo(area.left));
        expect(target.right, lessThanOrEqualTo(area.right));
        expect(target.top, current.top);
      }
    });
  });
}
