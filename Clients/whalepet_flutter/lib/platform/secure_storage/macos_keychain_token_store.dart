import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/config/token_store.dart';

/// macOS 令牌存储：Keychain 优先，并迁移旧版明文 `token.bin`。
///
/// 老版本把 Bearer 令牌以 0600 明文写到 `~/.whalepet/token.bin`。首次读取时
/// 自动搬到 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`），然后
/// 删除旧文件；写入只进 Keychain。
class MacOSKeychainTokenStore implements TokenStorage {
  MacOSKeychainTokenStore({required this.plaintextFallback});

  static const MethodChannel _channel = MethodChannel('whalepet/secure');

  /// 旧版明文存储，仅用于一次性迁移。
  final TokenStorage plaintextFallback;

  @override
  Future<String?> read() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('MacOSKeychainTokenStore 只能在 macOS 上使用');
    }
    final String? stored = await _invokeRead();
    if (stored != null && stored.isNotEmpty) return stored;

    final String? legacy = await plaintextFallback.read();
    if (legacy == null || legacy.isEmpty) return null;
    final bool migrated = await _invokeWrite(legacy);
    if (migrated) {
      await plaintextFallback.clear();
    }
    return legacy;
  }

  @override
  Future<void> write(String token) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('MacOSKeychainTokenStore 只能在 macOS 上使用');
    }
    final String trimmed = token.trim();
    if (trimmed.isEmpty) {
      await clear();
      return;
    }
    final bool ok = await _invokeWrite(trimmed);
    if (!ok) throw StateError('无法把令牌写入 macOS Keychain');
    // Keychain 写成功后删掉旧明文；写失败时保留旧文件，避免用户被锁在外面。
    await plaintextFallback.clear();
  }

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<bool>('delete');
    } on MissingPluginException {
      // 旧构建没有安全通道时仍至少清掉明文文件。
    }
    await plaintextFallback.clear();
  }

  Future<String?> _invokeRead() async {
    try {
      return await _channel.invokeMethod<String>('read');
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> _invokeWrite(String value) async {
    try {
      return await _channel.invokeMethod<bool>(
            'write',
            <String, dynamic>{'value': value},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
