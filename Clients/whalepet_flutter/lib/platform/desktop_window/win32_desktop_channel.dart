import 'dart:async';

import 'package:flutter/services.dart';

import '../../core/platform/desktop_tray.dart';

/// Windows runner 与 Dart 之间的桌面通道。
///
/// 原生侧（`windows/runner/flutter_window.cpp`）负责两件事：
///   - 托盘图标与菜单（用户点了什么 → `trayAction` 事件）；
///   - 显示器/工作区变化（`WM_DISPLAYCHANGE` / `WM_SETTINGCHANGE` /
///     `WM_DPICHANGED` → `displayChanged` 事件）。
///
/// Dart 侧负责两件事：
///   - `setTrayState`：把「窗口是否可见 / 语音唤醒是否开启」同步给托盘菜单；
///   - `quit`：落盘之后退出应用。
class Win32DesktopChannel {
  Win32DesktopChannel() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const MethodChannel _channel = MethodChannel('whalepet/desktop');

  final StreamController<DesktopNativeEvent> _events =
      StreamController<DesktopNativeEvent>.broadcast();

  /// 原生推给 Dart 的事件。
  Stream<DesktopNativeEvent> get events => _events.stream;

  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'displayChanged':
        if (!_events.isClosed) _events.add(const DesktopDisplayChangedEvent());
      case 'trayAction':
        final Object? raw = call.arguments;
        final DesktopTrayAction? action =
            raw is String ? _parseAction(raw) : null;
        if (action != null && !_events.isClosed) {
          _events.add(DesktopTrayActionEvent(action));
        }
    }
  }

  /// 原生动作名 → 枚举（与 `tray_icon.cpp` 里的动作名一一对应）。
  static DesktopTrayAction? _parseAction(String raw) {
    switch (raw) {
      case 'toggleVisible':
        return DesktopTrayAction.toggleVisible;
      case 'toggleVoice':
        return DesktopTrayAction.toggleVoice;
      case 'openSettings':
        return DesktopTrayAction.openSettings;
      case 'quit':
        return DesktopTrayAction.quit;
      default:
        return null;
    }
  }

  /// 同步托盘菜单状态。
  Future<void> setTrayState({
    required bool visible,
    required bool voiceEnabled,
  }) async {
    try {
      await _channel.invokeMethod<void>('setTrayState', <String, bool>{
        'visible': visible,
        'voiceEnabled': voiceEnabled,
      });
    } on MissingPluginException {
      // runner 没起来时忽略（单测/无原生层环境）。
    }
  }

  /// 退出应用（调用方应先落盘）。
  Future<void> quit() async {
    try {
      await _channel.invokeMethod<void>('quit');
    } on MissingPluginException {
      // 忽略：调用方会自己 exit。
    }
  }

  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

/// 原生推给 Dart 的桌面事件。
sealed class DesktopNativeEvent {
  const DesktopNativeEvent();
}

/// 显示器/工作区变了（插拔显示器、改分辨率、换主屏、DPI 变化）。
class DesktopDisplayChangedEvent extends DesktopNativeEvent {
  const DesktopDisplayChangedEvent();
}

/// 托盘菜单被点了一下。
class DesktopTrayActionEvent extends DesktopNativeEvent {
  const DesktopTrayActionEvent(this.action);

  final DesktopTrayAction action;
}
