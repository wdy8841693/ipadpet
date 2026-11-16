import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/platform/autostart.dart';

/// Windows 开机自启：写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`。
///
/// 选 HKCU 而不是 HKLM：不需要管理员权限，普通用户即可开关；
/// 写入的是**当前可执行文件的绝对路径**（带引号，兼容带空格的目录，
/// 例如便携包解压到 `D:\Program Files\WhalePet\`）。
///
/// 用 `dart:ffi` 直连 advapi32，不起 `reg.exe` 子进程：省一次进程开销，
/// 也不会因为路径里的引号/空格被命令行解析坑到。
class Win32Autostart implements AutostartController {
  Win32Autostart({this.valueName = 'WhalePet'});

  /// 注册表里的值名（同一个值名重复写入就是覆盖，不会堆积）。
  final String valueName;

  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

  static final int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)
      _regOpenKeyExW = _advapi32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32,
              Pointer<IntPtr>),
          int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>(
    'RegOpenKeyExW',
  );

  static final int Function(int, Pointer<Utf16>, Pointer<Uint32>,
      Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>) _regQueryValueExW =
      _advapi32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>,
              Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
          int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
              Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');

  static final int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)
      _regSetValueExW = _advapi32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32,
              Pointer<Uint8>, Uint32),
          int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)>(
    'RegSetValueExW',
  );

  static final int Function(int, Pointer<Utf16>) _regDeleteValueW =
      _advapi32.lookupFunction<
          Int32 Function(IntPtr, Pointer<Utf16>),
          int Function(int, Pointer<Utf16>)>('RegDeleteValueW');

  static final int Function(int) _regCloseKey = _advapi32.lookupFunction<
      Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

  // HKEY_CURRENT_USER / 权限位 / REG_SZ。
  static const int _hkeyCurrentUser = 0x80000001;
  static const int _keyRead = 0x20019;
  static const int _keySetValue = 0x0002;
  static const int _regSz = 1;

  static const String _runKeyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';

  @override
  Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    final int handle = _openKey(_keyRead);
    if (handle == 0) return false;
    try {
      final Pointer<Uint8> buffer = calloc<Uint8>(1024);
      final Pointer<Uint32> size = calloc<Uint32>();
      final Pointer<Uint32> type = calloc<Uint32>();
      final Pointer<Uint32> reserved = calloc<Uint32>();
      final Pointer<Utf16> name = valueName.toNativeUtf16();
      try {
        size.value = 1024;
        final int rc = _regQueryValueExW(
            handle, name, reserved, type, buffer, size);
        return rc == 0;
      } finally {
        calloc.free(name);
        calloc.free(reserved);
        calloc.free(type);
        calloc.free(size);
        calloc.free(buffer);
      }
    } finally {
      _regCloseKey(handle);
    }
  }

  @override
  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return false;
    if (!enabled) {
      final int handle = _openKey(_keySetValue);
      if (handle == 0) return false;
      try {
        final Pointer<Utf16> name = valueName.toNativeUtf16();
        try {
          // 值不存在时删除会返回 ERROR_FILE_NOT_FOUND，这里视为「已经是关的」。
          _regDeleteValueW(handle, name);
        } finally {
          calloc.free(name);
        }
      } finally {
        _regCloseKey(handle);
      }
      return true;
    }

    final int handle = _openKey(_keySetValue);
    if (handle == 0) return false;
    // 路径带引号，避免目录里有空格时被 Windows 截断。
    final String command = '"${Platform.resolvedExecutable}"';
    try {
      final Pointer<Utf16> name = valueName.toNativeUtf16();
      final Pointer<Utf16> data = command.toNativeUtf16();
      try {
        // REG_SZ 是以 L'\0' 结尾的 UTF-16 串，字节数含结尾。
        final int bytes = (command.length + 1) * 2;
        final int rc = _regSetValueExW(
            handle, name, 0, _regSz, data.cast<Uint8>(), bytes);
        return rc == 0;
      } finally {
        calloc.free(data);
        calloc.free(name);
      }
    } finally {
      _regCloseKey(handle);
    }
  }

  /// 打开 Run 键，失败返回 0。
  int _openKey(int access) {
    final Pointer<IntPtr> handle = calloc<IntPtr>();
    final Pointer<Utf16> path = _runKeyPath.toNativeUtf16();
    try {
      final int rc =
          _regOpenKeyExW(_hkeyCurrentUser, path, 0, access, handle);
      return rc == 0 ? handle.value : 0;
    } finally {
      calloc.free(path);
      calloc.free(handle);
    }
  }
}
