import 'dart:async';

import '../../core/platform/desktop_tray.dart';
import '../desktop_window/win32_desktop_channel.dart';

/// Windows 托盘图标适配层（§10.3）。
///
/// 图标本体在 runner（`tray_icon.cpp`，`Shell_NotifyIcon`），这里只做两件事：
///   - 把原生推来的动作转成 [DesktopTrayAction] 流；
///   - 把 Dart 侧的状态（窗口可见性、语音唤醒开关）同步回托盘菜单。
class Win32Tray implements DesktopTrayController {
  Win32Tray(this._channel) {
    _subscription = _channel.events.listen((DesktopNativeEvent event) {
      if (event is DesktopTrayActionEvent && !_actions.isClosed) {
        _actions.add(event.action);
      }
    });
  }

  final Win32DesktopChannel _channel;

  final StreamController<DesktopTrayAction> _actions =
      StreamController<DesktopTrayAction>.broadcast();
  StreamSubscription<DesktopNativeEvent>? _subscription;

  @override
  Stream<DesktopTrayAction> get actions => _actions.stream;

  @override
  Future<void> updateState({
    required bool visible,
    required bool voiceEnabled,
  }) =>
      _channel.setTrayState(visible: visible, voiceEnabled: voiceEnabled);

  /// 退出：交给 runner 结束消息循环（比 `exit(0)` 干净，窗口与资源能被回收）。
  @override
  Future<void> quit() => _channel.quit();

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_actions.isClosed) await _actions.close();
  }
}
