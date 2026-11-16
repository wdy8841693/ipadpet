import 'package:test/test.dart';
import 'package:whalepet_flutter/core/config/app_settings.dart';
import 'package:whalepet_flutter/core/voice/voice_engine.dart';

/// 设置与语音配置的往返（§10.3 开机自启、§7.7 一句话带命令）。
void main() {
  group('AppSettings', () {
    test('新字段能存能读', () {
      final AppSettings settings = AppSettings(
        autostartEnabled: true,
        oneShotCommandEnabled: false,
      );
      final AppSettings restored = AppSettings.fromJson(settings.toJson());
      expect(restored.autostartEnabled, isTrue);
      expect(restored.oneShotCommandEnabled, isFalse);
    });

    test('老配置（没有新字段）回落默认值', () {
      final AppSettings restored = AppSettings.fromJson(
        <String, dynamic>{'schema_version': 1, 'server_url': 'http://1.2.3.4:8787'},
      );
      expect(restored.autostartEnabled, isFalse);
      expect(restored.oneShotCommandEnabled, isFalse);
    });

    test('一句话带命令默认关闭：通用听写认不出自定义唤醒词', () {
      expect(AppSettings().oneShotCommandEnabled, isFalse);
      expect(const VoiceEngineConfig().oneShotCommand, isFalse);
    });

    test('copyWith 不影响别的字段', () {
      final AppSettings settings = AppSettings(serverUrl: 'http://a:8787');
      final AppSettings next =
          settings.copyWith(autostartEnabled: true, oneShotCommandEnabled: false);
      expect(next.serverUrl, 'http://a:8787');
      expect(next.autostartEnabled, isTrue);
      expect(next.oneShotCommandEnabled, isFalse);
    });
  });

  group('VoiceEngineConfig', () {
    test('一句话带命令开关进 JSON（Windows 引擎据此选待机策略）', () {
      const VoiceEngineConfig config = VoiceEngineConfig(
        oneShotCommand: true,
      );
      expect(config.toJson()['one_shot_command'], isTrue);
      expect(
        const VoiceEngineConfig(oneShotCommand: false)
            .toJson()['one_shot_command'],
        isFalse,
      );
    });

    test('唤醒词表含别名且按长度去重', () {
      const VoiceEngineConfig config = VoiceEngineConfig(
        wakePhrase: '小鲸小鲸',
        wakeAliases: <String>['小金小金', '小鲸小鲸'],
      );
      expect(config.wakePhrases, <String>['小鲸小鲸', '小金小金']);
    });
  });
}
