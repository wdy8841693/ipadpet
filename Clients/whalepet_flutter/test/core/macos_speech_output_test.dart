import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whalepet_flutter/core/voice/speech_output.dart';
import 'package:whalepet_flutter/platform/speech_output/macos_speech.dart';

/// 回归：macOS 的 speak() 必须等真实 AVSpeechSynthesizer 完成事件。
///
/// 旧实现只等 MethodChannel 的启动回包（原生立即返回），协调器会提前
/// 结束播报、恢复麦克风并启动下一句，可能自己把自己唤醒。
void main() {
  if (!Platform.isMacOS) return;
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('whalepet/speech');
  const StandardMethodCodec codec = StandardMethodCodec();

  Future<void> pushNativeEvent(String kind, String utteranceId) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'whalepet/speech',
      codec.encodeMethodCall(MethodCall('event', <String, dynamic>{
        'kind': kind,
        'utteranceId': utteranceId,
      })),
      (_) {},
    );
    await pumpEventQueue();
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('speak 等真实完成事件才返回', () async {
    final MacOSSpeechOutput output = MacOSSpeechOutput();
    final List<SpeechOutputEvent> events = <SpeechOutputEvent>[];
    output.events.listen(events.add);
    await output.initialize();

    bool completed = false;
    final Future<void> speaking = output.speak('utt-1', '我在');
    speaking.then((_) => completed = true);
    await pumpEventQueue();
    expect(completed, isFalse, reason: 'MethodChannel 启动回包不是播报完成');

    await pushNativeEvent('finished', 'utt-1');
    await speaking;
    expect(completed, isTrue);
    expect(
      events.where((SpeechOutputEvent e) => e.utteranceId == 'utt-1').map(
            (SpeechOutputEvent e) => e.kind,
          ),
      contains(SpeechOutputEventKind.finished),
    );

    await output.dispose();
  });

  test('主动 stop 会结束正在等待的 speak', () async {
    final MacOSSpeechOutput output = MacOSSpeechOutput();
    await output.initialize();

    final Future<void> speaking = output.speak('utt-2', '回答');
    await pumpEventQueue();
    await output.stop();
    await speaking;

    await output.dispose();
  }, timeout: const Timeout(Duration(seconds: 5)));
}
