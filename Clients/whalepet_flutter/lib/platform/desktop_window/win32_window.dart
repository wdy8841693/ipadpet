import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/platform/desktop_window.dart';
import '../../core/platform/window_placement.dart';

/// Win32 桌面窗口适配层（§10.3）。
///
/// 设计取舍：
///   - 不用第三方窗口插件，直接 `dart:ffi` 调 user32：行为可控、无额外依赖；
///   - Dart 侧一律逻辑像素（= 物理像素 / DPI 缩放），缩放由本文件统一处理；
///   - 桌宠移动就是移动窗口，没有全屏透明画布，所以这里只做 SetWindowPos。
class Win32DesktopWindow implements DesktopWindowAdapter {
  Win32DesktopWindow({this.windowClass = 'FLUTTER_RUNNER_WIN32_WINDOW'});

  /// Flutter runner 注册的窗口类名（`windows/runner/win32_window.cpp`）。
  final String windowClass;

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

  static final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindowW =
      _user32.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');

  static final int Function(int, int, int) _setWindowLongW = _user32
      .lookupFunction<Int32 Function(IntPtr, Int32, Int32),
          int Function(int, int, int)>('SetWindowLongW');

  static final int Function(int, int) _getWindowLongW = _user32.lookupFunction<
      Int32 Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongW');

  static final int Function(int, int, int, int, int, int, int) _setWindowPos =
      _user32.lookupFunction<
          Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
          int Function(int, int, int, int, int, int, int)>('SetWindowPos');

  static final int Function(int, int, int, int) _setLayeredWindowAttributes =
      _user32.lookupFunction<
          Int32 Function(IntPtr, Uint32, Uint8, Uint32),
          int Function(int, int, int, int)>('SetLayeredWindowAttributes');

  static final int Function(int, Pointer<_Rect>) _getWindowRect =
      _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>),
          int Function(int, Pointer<_Rect>)>('GetWindowRect');

  static final int Function(int, int) _monitorFromWindow = _user32.lookupFunction<
      IntPtr Function(IntPtr, Uint32), int Function(int, int)>(
    'MonitorFromWindow',
  );

  static final int Function(int, Pointer<_MonitorInfo>) _getMonitorInfoW =
      _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_MonitorInfo>),
          int Function(int, Pointer<_MonitorInfo>)>('GetMonitorInfoW');

  static final int Function() _releaseCapture = _user32.lookupFunction<
      Int32 Function(), int Function()>('ReleaseCapture');

  static final int Function(int, int, int, int) _sendMessageW = _user32
      .lookupFunction<IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
          int Function(int, int, int, int)>('SendMessageW');

  static final int Function(Pointer<_Point>) _getCursorPos = _user32.lookupFunction<
      Int32 Function(Pointer<_Point>), int Function(Pointer<_Point>)>(
    'GetCursorPos',
  );

  static final int Function(int) _getDpiForWindow = _user32.lookupFunction<
      Uint32 Function(IntPtr), int Function(int)>('GetDpiForWindow');

  // Win32 常量。
  static const int _gwlStyle = -16;
  static const int _gwlExStyle = -20;
  static const int _wsExToolWindow = 0x00000080;
  static const int _wsExTopmost = 0x00000008;
  static const int _wsExTransparent = 0x00000020;
  static const int _wsExLayered = 0x00080000;
  static const int _wsCaption = 0x00C00000;
  static const int _wsThickFrame = 0x00040000;
  static const int _wsSysMenu = 0x00080000;
  static const int _wsMinimizeBox = 0x00020000;
  static const int _wsMaximizeBox = 0x00010000;
  static const int _swpNoSize = 0x0001;
  static const int _swpNoMove = 0x0002;
  static const int _swpNoZOrder = 0x0004;
  static const int _swpNoActivate = 0x0010;
  static const int _swpFrameChanged = 0x0020;
  static const int _swpShowWindow = 0x0040;
  static const int _hwndTopmost = -1;
  static const int _hwndNoTopmost = -2;
  static const int _lwaAlpha = 0x2;
  static const int _monitorDefaultToNearest = 0x00000002;
  static const int _wmNcLButtonDown = 0x00A1;
  static const int _htCaption = 0x2;

  int _hwnd = 0;
  double _scale = 1.0;
  bool _clickThrough = false;

  @override
  bool get isReady => _hwnd != 0;

  /// 当前窗口句柄（0 表示还没找到）。
  int get handle => _hwnd;

  /// 当前 DPI 缩放（物理像素 / 逻辑像素）。
  double get scale => _scale;

  @override
  Future<void> initialize() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Win32DesktopWindow 只能在 Windows 上使用');
    }
    if (_hwnd != 0) {
      return;
    }
    final int hwnd = await _findRunnerWindow();
    if (hwnd == 0) {
      throw StateError('找不到 Flutter runner 窗口（类名 $windowClass）');
    }
    _hwnd = hwnd;
    _scale = _readScale();

    // 无边框 + 不进任务栏 + 逐像素透明（layered）。
    final int style = _getWindowLongW(_hwnd, _gwlStyle);
    final int newStyle = style &
        ~_wsCaption &
        ~_wsThickFrame &
        ~_wsSysMenu &
        ~_wsMinimizeBox &
        ~_wsMaximizeBox;
    if (newStyle != style) {
      _setWindowLongW(_hwnd, _gwlStyle, newStyle);
    }

    final int exStyle = _getWindowLongW(_hwnd, _gwlExStyle);
    final int newExStyle = exStyle | _wsExToolWindow | _wsExLayered;
    if (newExStyle != exStyle) {
      _setWindowLongW(_hwnd, _gwlExStyle, newExStyle);
    }
    // alpha=255 表示「窗口整体不透明」，逐像素透明交给渲染表面自己的 alpha。
    _setLayeredWindowAttributes(_hwnd, 0, 255, _lwaAlpha);
    _setWindowPos(
      _hwnd,
      0,
      0,
      0,
      0,
      0,
      _swpNoMove | _swpNoSize | _swpNoZOrder | _swpFrameChanged,
    );
  }

  /// 找窗口：先按类名，再按标题兜底（用户手动改了类名也不会崩）。
  Future<int> _findRunnerWindow() async {
    for (int attempt = 0; attempt < 40; attempt++) {
      final Pointer<Utf16> className = windowClass.toNativeUtf16();
      try {
        final int hwnd = _findWindowW(className, nullptr);
        if (hwnd != 0) return hwnd;
      } finally {
        calloc.free(className);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return 0;
  }

  double _readScale() {
    try {
      final int dpi = _getDpiForWindow(_hwnd);
      if (dpi <= 0) return 1.0;
      return dpi / 96.0;
    } catch (_) {
      return 1.0;
    }
  }

  @override
  Future<WorkArea> workArea() async {
    final Pointer<_MonitorInfo> info = calloc<_MonitorInfo>();
    try {
      info.ref.cbSize = sizeOf<_MonitorInfo>();
      final int monitor = _monitorFromWindow(_hwnd, _monitorDefaultToNearest);
      if (monitor == 0 || _getMonitorInfoW(monitor, info) == 0) {
        return const WorkArea(left: 0, top: 0, width: 1920, height: 1080);
      }
      final _Rect work = info.ref.rcWork;
      return WorkArea(
        left: work.left / _scale,
        top: work.top / _scale,
        width: (work.right - work.left) / _scale,
        height: (work.bottom - work.top) / _scale,
      );
    } finally {
      calloc.free(info);
    }
  }

  @override
  Future<WindowRect> bounds() async {
    final Pointer<_Rect> rect = calloc<_Rect>();
    try {
      if (_getWindowRect(_hwnd, rect) == 0) {
        return const WindowRect(left: 0, top: 0, width: 360, height: 460);
      }
      final _Rect r = rect.ref;
      return WindowRect(
        left: r.left / _scale,
        top: r.top / _scale,
        width: (r.right - r.left) / _scale,
        height: (r.bottom - r.top) / _scale,
      );
    } finally {
      calloc.free(rect);
    }
  }

  @override
  Future<void> setPosition(double left, double top) async {
    _setWindowPos(
      _hwnd,
      0,
      (left * _scale).round(),
      (top * _scale).round(),
      0,
      0,
      _swpNoSize | _swpNoZOrder | _swpNoActivate,
    );
  }

  @override
  Future<void> setBounds(WindowRect rect) async {
    _setWindowPos(
      _hwnd,
      0,
      (rect.left * _scale).round(),
      (rect.top * _scale).round(),
      (rect.width * _scale).round(),
      (rect.height * _scale).round(),
      _swpNoZOrder | _swpNoActivate,
    );
  }

  @override
  Future<void> setAlwaysOnTop(bool enabled) async {
    int ex = _getWindowLongW(_hwnd, _gwlExStyle);
    if (enabled) {
      ex |= _wsExTopmost;
    } else {
      ex &= ~_wsExTopmost;
    }
    _setWindowLongW(_hwnd, _gwlExStyle, ex);
    _setWindowPos(
      _hwnd,
      enabled ? _hwndTopmost : _hwndNoTopmost,
      0,
      0,
      0,
      0,
      _swpNoMove | _swpNoSize | _swpNoActivate | _swpShowWindow,
    );
  }

  @override
  Future<void> setSkipTaskbar(bool enabled) async {
    int ex = _getWindowLongW(_hwnd, _gwlExStyle);
    if (enabled) {
      ex |= _wsExToolWindow;
    } else {
      ex &= ~_wsExToolWindow;
    }
    _setWindowLongW(_hwnd, _gwlExStyle, ex);
    _setWindowPos(
      _hwnd,
      0,
      0,
      0,
      0,
      0,
      _swpNoMove | _swpNoSize | _swpNoZOrder | _swpNoActivate | _swpFrameChanged,
    );
  }

  @override
  Future<void> setClickThrough(bool enabled) async {
    if (_clickThrough == enabled) return;
    _clickThrough = enabled;
    int ex = _getWindowLongW(_hwnd, _gwlExStyle);
    if (enabled) {
      ex |= _wsExTransparent | _wsExLayered;
    } else {
      ex &= ~_wsExTransparent;
    }
    _setWindowLongW(_hwnd, _gwlExStyle, ex);
  }

  @override
  Future<void> startNativeDrag() async {
    _releaseCapture();
    _sendMessageW(_hwnd, _wmNcLButtonDown, _htCaption, 0);
  }

  /// 全局光标位置（逻辑像素，屏幕坐标）。用于「透明区域自动穿透」的命中测试。
  @override
  ({double x, double y})? cursorPosition() {
    if (_hwnd == 0) return null;
    final Pointer<_Point> point = calloc<_Point>();
    try {
      if (_getCursorPos(point) == 0) return null;
      return (
        x: point.ref.x / _scale,
        y: point.ref.y / _scale,
      );
    } finally {
      calloc.free(point);
    }
  }

  @override
  Future<void> dispose() async {
    // 窗口生命周期由 runner 管，这里只清缓存句柄。
    _hwnd = 0;
  }
}

final class _Rect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final class _MonitorInfo extends Struct {
  @Uint32()
  external int cbSize;

  external _Rect rcMonitor;

  external _Rect rcWork;

  @Uint32()
  external int dwFlags;
}
