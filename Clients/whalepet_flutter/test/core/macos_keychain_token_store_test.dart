import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whalepet_flutter/core/config/token_store.dart';
import 'package:whalepet_flutter/platform/secure_storage/macos_keychain_token_store.dart';

class FakeTokenStore implements TokenStorage {
  String? value;
  int clearCalls = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;

  @override
  Future<void> clear() async {
    clearCalls += 1;
    value = null;
  }
}

void main() {
  if (!Platform.isMacOS) return;
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('whalepet/secure');
  String? keychain;

  setUp(() {
    keychain = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'read':
          return keychain;
        case 'write':
          keychain = (call.arguments as Map<dynamic, dynamic>)['value'] as String;
          return true;
        case 'delete':
          keychain = null;
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('旧明文令牌首次读取后迁入 Keychain 并清掉文件', () async {
    final FakeTokenStore legacy = FakeTokenStore()..value = 'old-token';
    final MacOSKeychainTokenStore store = MacOSKeychainTokenStore(
      plaintextFallback: legacy,
    );

    expect(await store.read(), 'old-token');
    expect(keychain, 'old-token');
    expect(legacy.clearCalls, 1);
    expect(legacy.value, isNull);
  });

  test('写入令牌只进 Keychain，并清掉旧明文', () async {
    final FakeTokenStore legacy = FakeTokenStore()..value = 'old-token';
    final MacOSKeychainTokenStore store = MacOSKeychainTokenStore(
      plaintextFallback: legacy,
    );

    await store.write('new-token');
    expect(keychain, 'new-token');
    expect(legacy.value, isNull);
    expect(await store.read(), 'new-token');
  });
}
