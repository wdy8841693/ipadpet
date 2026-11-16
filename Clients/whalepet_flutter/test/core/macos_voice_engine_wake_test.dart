import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whalepet_flutter/core/voice/voice_engine.dart';
import 'package:whalepet_flutter/platform/voice/macos_voice_engine.dart';

/// macOS 原生 KWS（sherpa-onnx）命中后的事件通路。
///
/// 原生层在关键词模型判定命中时推一条 `{"type":"wake","keyword":"…"}` 事件；
/// 适配层把它转成文本交给路由，由路由按用户配置的唤醒词表做最终判定——
/// 这样「用户换了唤醒词」时不会误触发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('whalepet/voice');
  const StandardMethodCodec codec = StandardMethodCodec();

  /// 模拟原生 → Dart 的事件推送。
  Future<void> pushNativeEvent(Map<String, dynamic> payload) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'whalepet/voice',
      codec.encodeMethodCall(MethodCall('event', payload)),
      (_) {},
    );
    await pumpEventQueue();
  }

  void mockChannel({String wakeProvider = 'kws'}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'initialize':
          return <String, dynamic>{
            'provider': 'apple-speech/zh-CN',
            'onDevice': true,
            'wakeProvider': wakeProvider,
          };
        default:
          return null;
      }
    });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('原生 KWS 命中唤醒词 → 路由出唤醒事件', () async {
    mockChannel();
    final MacOSVoiceEngine engine = MacOSVoiceEngine();
    final List<VoiceEngineEvent> events = <VoiceEngineEvent>[];
    engine.events.listen(events.add);

    await engine.initialize(const VoiceEngineConfig());
    await pumpEventQueue();
    await engine.startWakeListening();

    await pushNativeEvent(<String, dynamic>{
      'type': 'wake',
      'mode': 'wake',
      'keyword': '小鲸小鲸',
    });

    final List<VoiceWakeDetectedEvent> wakes = events
        .whereType<VoiceWakeDetectedEvent>()
        .toList();
    expect(wakes.length, 1);
    expect(wakes.first.keyword, '小鲸小鲸');

    await engine.dispose();
  });

  test('原生命中的词不在用户唤醒词表里 → 不触发唤醒', () async {
    mockChannel();
    final MacOSVoiceEngine engine = MacOSVoiceEngine();
    final List<VoiceEngineEvent> events = <VoiceEngineEvent>[];
    engine.events.listen(events.add);

    await engine.initialize(const VoiceEngineConfig());
    await pumpEventQueue();
    await engine.startWakeListening();

    await pushNativeEvent(<String, dynamic>{
      'type': 'wake',
      'mode': 'wake',
      'keyword': '小海豚',
    });

    expect(events.whereType<VoiceWakeDetectedEvent>(), isEmpty);

    await engine.dispose();
  });

  test('引擎信息里标明唤醒方式（本地唤醒词 / 文本匹配）', () async {
    mockChannel(wakeProvider: 'text-match');
    final MacOSVoiceEngine engine = MacOSVoiceEngine();
    final List<VoiceEngineEvent> events = <VoiceEngineEvent>[];
    engine.events.listen(events.add);

    await engine.initialize(const VoiceEngineConfig());
    await pumpEventQueue();

    final VoiceEngineReadyEvent? ready =
        events.whereType<VoiceEngineReadyEvent>().firstOrNull;
    expect(ready, isNotNull);
    expect(ready!.detail, contains('文本匹配'));

    await engine.dispose();
  });
}
