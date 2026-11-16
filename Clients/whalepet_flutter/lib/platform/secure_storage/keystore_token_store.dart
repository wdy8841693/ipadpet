import 'dart:async';

import '../../core/config/token_store.dart';
import '../android/native_bridge.dart';

/// Android 上的 Bearer 令牌存储（§11.2）。
///
/// 令牌交给原生层用 Android Keystore 里的 AES-GCM 密钥加密后存进
/// SharedPreferences（密文），Dart 侧只拿到明文，
/// 密钥不出 Keystore、也不进备份。
class KeystoreTokenStore implements TokenStorage {
  const KeystoreTokenStore();

  static const String _key = 'whalepet.bearer';

  @override
  Future<String?> read() async {
    try {
      final String? value = await NativeBridge.secureRead(_key);
      final String trimmed = (value ?? '').trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String token) async {
    final String trimmed = token.trim();
    if (trimmed.isEmpty) {
      await clear();
      return;
    }
    await NativeBridge.secureWrite(_key, trimmed);
  }

  @override
  Future<void> clear() async {
    try {
      await NativeBridge.secureWrite(_key, '');
    } catch (_) {
      // 清不掉也不该让设置保存失败
    }
  }
}
