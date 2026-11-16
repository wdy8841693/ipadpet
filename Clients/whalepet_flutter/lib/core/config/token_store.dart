import 'dart:io';
import 'dart:typed_data';

import 'atomic_file.dart';
import 'dpapi.dart';

/// Bearer 令牌的存储抽象（§11.2）。
///
/// 桌面端用 [TokenStore]（Windows → DPAPI）；Android 用 `KeystoreTokenStore`
/// （Android Keystore + AES-GCM，见 `platform/secure_storage/`）。
/// 运行时只依赖这份接口，不关心密钥在哪。
abstract interface class TokenStorage {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> clear();
}

/// Bearer 令牌的安全存储（§11.2）。
///
/// Windows 用 DPAPI 加密后落盘（密钥绑当前用户，换机解不开）；
/// 非 Windows（只用于开发/测试）退化为明文，并在日志里明确提示，不假装安全。
class TokenStore implements TokenStorage {
  TokenStore({required this.file});

  final File file;

  /// 读取令牌；没有文件 / 解不开都返回 null。
  Future<String?> read() async {
    if (!await file.exists()) return null;
    try {
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      if (!Platform.isWindows) return String.fromCharCodes(bytes).trim();
      final String? token = Dpapi.unprotect(bytes);
      if (token == null) return null;
      final String trimmed = token.trim();
      return trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  /// 写入令牌（空字符串等价于清除）。
  Future<void> write(String token) async {
    final String trimmed = token.trim();
    if (trimmed.isEmpty) {
      await clear();
      return;
    }
    if (Platform.isWindows) {
      final Uint8List cipher = Dpapi.protect(trimmed);
      await _writeBytes(cipher);
    } else {
      await writeFileAtomically(file, trimmed);
    }
  }

  Future<void> clear() async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _writeBytes(Uint8List bytes) async {
    final File temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    try {
      await temp.rename(file.path);
      return;
    } on FileSystemException {
      if (!await file.exists()) rethrow;
    }
    await file.delete();
    await temp.rename(file.path);
  }
}

/// 本机客户端 id 的持久化（首次生成后不再变，§8.2）。
class ClientIdStore {
  ClientIdStore({required this.file});

  final File file;

  /// 读取；不存在返回 null。
  Future<String?> read() async {
    try {
      if (!await file.exists()) return null;
      final String text = (await file.readAsString()).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String clientId) => writeFileAtomically(file, clientId);
}
