import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/platform/desktop_window.dart';
import '../../core/platform/window_placement.dart';

/// macOS 桌面窗口适配层（§10.2）。
///
/// 设计取舍：
///   - 窗口样式（透明 / 无边框 / 置顶 / 全空间 / 不进 Dock）由原生 Swift 在
///     `macos/Runner` 里设置，Dart 通过 MethodChannel `whalepet/window` 下发指令；
///   - 坐标约定与 Win32 版一致：Dart 侧一律「逻辑像素 + 左上角原点」的屏幕坐标，
///     Cocoa 的「底部左原点」换算全部封在原生层；
///   - 唯一用 FFI 的地方是全局光标：CoreGraphics 的光标坐标恰好就是
///     「左上角原点」的全局坐标，与 Dart 语义直接对齐，而且接口是同步的
///     （`cursorPosition()` 在 `DesktopWindowAdapter` 里是同步方法，不能走 channel）。
class MacOSDesktopWindow
    implements
        DesktopWindowAdapter,
        DisplayChangeAware,
        WindowVisibilityAware,
        WindowActivator {
  MacOSDesktopWindow() {
    // 原生侧在「显示器参数变化」时会回调这个通道，桌宠据此重新约束位置。
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const MethodChannel _channel = MethodChannel('whalepet/window');

  final StreamController<void> _displayChanges =
      StreamController<void>.broadcast();

  bool _ready = false;
  bool _visible = true;

  @override
  Stream<void> get displayChanges => _displayChanges.stream;

  @override
  bool get isVisible => _visible;

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'screensChanged') {
      if (!_displayChanges.isClosed) _displayChanges.add(null);
    }
  }

  // -- CoreGraphics FFI：全局光标位置 ---------------------------------------

  static DynamicLibrary? _coreGraphics;

  // CGEventCreate 的 C 签名是 `CGEventRef CGEventCreate(CGEventSourceRef source)`，
  // 必须传一个 source（传 nullptr 表示默认事件源）。之前误声明成无参函数，
  // 调用时第一个参数寄存器是残留值，真机上 CGEventCreate 直接返回 NULL，
  // 于是 cursorPosition() 永远返回 null、透明穿透从启动起全程失效。
  static final Pointer<Void> Function(Pointer<Void>) _cgEventCreate = _loadCg()
      .lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('CGEventCreate');

  static final _CGPoint Function(Pointer<Void>) _cgEventGetLocation =
      _loadCg().lookupFunction<
          _CGPoint Function(Pointer<Void>),
          _CGPoint Function(Pointer<Void>)>('CGEventGetLocation');

  static final void Function(Pointer<Void>) _cfRelease = _loadCg()
      .lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('CFRelease');

  static DynamicLibrary _loadCg() {
    if (_coreGraphics != null) return _coreGraphics!;
    // 路径写死官方框架位置，macOS 13+ 在 /System/Library 下都可命中。
    _coreGraphics = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    return _coreGraphics!;
  }

  @override
  bool get isReady => _ready;

  @override
  Future<void> initialize() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('MacOSDesktopWindow 只能在 macOS 上使用');
    }
    await _channel.invokeMethod<dynamic>('initialize');
    _ready = true;
  }

  @override
  Future<WorkArea> workArea() async {
    final Map<dynamic, dynamic> data =
        await _channel.invokeMethod<Map<dynamic, dynamic>>('workArea') ??
            const <dynamic, dynamic>{};
    return WorkArea(
      left: _d(data['left']),
      top: _d(data['top']),
      width: _d(data['width']),
      height: _d(data['height']),
    );
  }

  @override
  Future<WindowRect> bounds() async {
    final Map<dynamic, dynamic> data =
        await _channel.invokeMethod<Map<dynamic, dynamic>>('bounds') ??
            const <dynamic, dynamic>{};
    return WindowRect(
      left: _d(data['left']),
      top: _d(data['top']),
      width: _d(data['width']),
      height: _d(data['height']),
    );
  }

  @override
  Future<void> setPosition(double left, double top) =>
      _channel.invokeMethod<dynamic>(
        'setPosition',
        <String, double>{'left': left, 'top': top},
      );

  @override
  Future<void> setBounds(WindowRect rect) => _channel.invokeMethod<dynamic>(
        'setBounds',
        <String, double>{
          'left': rect.left,
          'top': rect.top,
          'width': rect.width,
          'height': rect.height,
        },
      );

  @override
  Future<void> setAlwaysOnTop(bool enabled) =>
      _channel.invokeMethod<dynamic>(
        'setAlwaysOnTop',
        <String, bool>{'enabled': enabled},
      );

  @override
  Future<void> setSkipTaskbar(bool enabled) =>
      _channel.invokeMethod<dynamic>(
        'setSkipTaskbar',
        <String, bool>{'enabled': enabled},
      );

  @override
  Future<void> setClickThrough(bool enabled) =>
      _channel.invokeMethod<dynamic>(
        'setClickThrough',
        <String, bool>{'enabled': enabled},
      );

  /// 显示/隐藏窗口（托盘/菜单栏「显示宠物」）。
  @override
  Future<void> setVisible(bool visible) async {
    await _channel.invokeMethod<dynamic>(
      'setVisible',
      <String, bool>{'visible': visible},
    );
    _visible = visible;
  }

  @override
  Future<void> startNativeDrag() => _channel.invokeMethod<dynamic>(
    'startNativeDrag',
  );

  /// 打开设置/聊天面板时激活窗口。
  ///
  /// 桌宠是 accessory（不进 Dock）应用，默认不抢焦点；窗口又是无边框的，
  /// 不显式激活就拿不到 key window 状态，文本框打不进字。
  @override
  Future<void> activate() async {
    try {
      await _channel.invokeMethod<dynamic>('activate');
    } catch (_) {
      // 旧构建没有这个方法：忽略，不影响其它功能。
    }
  }

  @override
  ({double x, double y})? cursorPosition() {
    if (!Platform.isMacOS) return null;
    final Pointer<Void> event = _cgEventCreate(nullptr);
    if (event == nullptr) return null;
    try {
      final _CGPoint point = _cgEventGetLocation(event);
      // CG 光标坐标本身就是「左上角原点」的全局逻辑坐标，直接对齐 Dart 语义。
      return (x: point.x, y: point.y);
    } finally {
      _cfRelease(event);
    }
  }

  @override
  Future<void> dispose() async {
    // 窗口由原生层持有，App 退出时统一释放；这里只复位状态。
    _ready = false;
    if (!_displayChanges.isClosed) await _displayChanges.close();
  }

  static double _d(Object? value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
}

/// CoreGraphics 的 `CGPoint`。
final class _CGPoint extends Struct {
  @Double()
  external double x;

  @Double()
  external double y;
}
