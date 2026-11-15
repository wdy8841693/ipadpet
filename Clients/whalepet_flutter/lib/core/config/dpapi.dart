import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows DPAPI 加密（`CryptProtectData` / `CryptUnprotectData`）。
///
/// 规则来源：`docs/CROSS_PLATFORM.md` §11.2「Bearer 令牌必须进入安全存储」。
/// Windows 上对应 DPAPI：密钥绑当前用户账号，换机/换账号解不开，不用自己管密钥。
///
/// 只用 `dart:ffi` + 官方的 `package:ffi` 分配器，不引任何窗口/系统插件。
class Dpapi {
  Dpapi._();

  static final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final int Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  ) _cryptProtectData = _crypt32.lookupFunction<
      Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
          Pointer<Void>, Pointer<Void>, Int32, Pointer<_DataBlob>),
      int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
          Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>)>(
    'CryptProtectData',
  );

  static final int Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  ) _cryptUnprotectData = _crypt32.lookupFunction<
      Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
          Pointer<Void>, Pointer<Void>, Int32, Pointer<_DataBlob>),
      int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>,
          Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>)>(
    'CryptUnprotectData',
  );

  static final Pointer<Void> Function(Pointer<Void>) _localFree =
      _kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)>('LocalFree');

  /// 附加熵：把这批密文绑到本应用，别的程序拿到文件也解不开。
  static const String _entropyLabel = 'whalepet-dsh-token-v1';

  /// 加密一段文本，返回密文字节。
  static Uint8List protect(String plainText) {
    final Uint8List data = utf8.encode(plainText);
    final Uint8List entropy = utf8.encode(_entropyLabel);
    return _call(data, entropy, protectMode: true);
  }

  /// 解密；失败（换账号、文件被改）返回 null，调用方按「没配置令牌」处理。
  static String? unprotect(Uint8List cipher) {
    final Uint8List entropy = utf8.encode(_entropyLabel);
    final Uint8List plain;
    try {
      plain = _call(cipher, entropy, protectMode: false);
    } catch (_) {
      return null;
    }
    return utf8.decode(plain, allowMalformed: true);
  }

  static Uint8List _call(
    Uint8List input,
    Uint8List entropy, {
    required bool protectMode,
  }) {
    final Pointer<_DataBlob> inBlob = calloc<_DataBlob>();
    final Pointer<_DataBlob> entropyBlob = calloc<_DataBlob>();
    final Pointer<_DataBlob> outBlob = calloc<_DataBlob>();
    Pointer<Uint8> inBuffer = nullptr;
    Pointer<Uint8> entropyBuffer = nullptr;
    try {
      inBuffer = calloc<Uint8>(input.isEmpty ? 1 : input.length);
      if (input.isNotEmpty) inBuffer.asTypedList(input.length).setAll(0, input);
      inBlob.ref.cbData = input.length;
      inBlob.ref.pbData = inBuffer;

      entropyBuffer = calloc<Uint8>(entropy.length);
      entropyBuffer.asTypedList(entropy.length).setAll(0, entropy);
      entropyBlob.ref.cbData = entropy.length;
      entropyBlob.ref.pbData = entropyBuffer;

      const int flags = 0x1; // CRYPTPROTECT_UI_FORBIDDEN：不弹系统对话框。
      final int ok = protectMode
          ? _cryptProtectData(
              inBlob, nullptr, entropyBlob, nullptr, nullptr, flags, outBlob)
          : _cryptUnprotectData(
              inBlob, nullptr, entropyBlob, nullptr, nullptr, flags, outBlob);
      if (ok == 0) {
        throw StateError(
          protectMode ? 'CryptProtectData 失败' : 'CryptUnprotectData 失败',
        );
      }
      final int size = outBlob.ref.cbData;
      final Pointer<Uint8> data = outBlob.ref.pbData;
      return Uint8List.fromList(data.asTypedList(size));
    } finally {
      if (outBlob.ref.pbData != nullptr) _localFree(outBlob.ref.pbData.cast());
      if (inBuffer != nullptr) calloc.free(inBuffer);
      if (entropyBuffer != nullptr) calloc.free(entropyBuffer);
      calloc.free(inBlob);
      calloc.free(entropyBlob);
      calloc.free(outBlob);
    }
  }
}

/// DPAPI 的 `DATA_BLOB`：`DWORD cbData; BYTE *pbData;`
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}
