import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whalepet_flutter/platform/desktop_window/macos_window.dart';

/// 真机 FFI 回归：CGEventCreate 必须传 nullptr 作为 source。
///
/// 之前把 `CGEventCreate` 误声明成无参函数，真机上它返回 NULL，
/// `cursorPosition()` 永远为 null，导致透明区穿透从启动起全程失效。
/// 假窗口测试手动喂光标，无法覆盖这条 FFI 链路，所以这里直接调真实实现。
void main() {
  test('macOS 上 cursorPosition 能通过真实 FFI 读到光标', () {
    if (!Platform.isMacOS) return; // 非 macOS 平台跳过

    TestWidgetsFlutterBinding.ensureInitialized();
    final MacOSDesktopWindow window = MacOSDesktopWindow();
    final ({double x, double y})? cursor = window.cursorPosition();
    expect(cursor, isNotNull,
        reason: 'CGEventCreate(nullptr) 必须返回有效 event，否则透明穿透永远不生效');
    expect(cursor!.x, isA<double>());
    expect(cursor.y, isA<double>());
  });
}
