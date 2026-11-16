// 开发验证工具：确认常驻播报进程能连续播两条（stdin 吞命令的回归测试）。
//
// 用法：dart run tool/verify_tts.dart
//
// 不依赖 Flutter，直接在 Windows 上跑 PowerShellSpeechOutput。

import 'dart:async';
import 'dart:io';

import '../lib/core/voice/speech_output.dart';
import '../lib/platform/speech_output/powershell_speech.dart';

Future<void> main() async {
  final PowerShellSpeechOutput tts = PowerShellSpeechOutput();
  final List<SpeechOutputEvent> events = <SpeechOutputEvent>[];
  final StreamSubscription<SpeechOutputEvent> sub =
      tts.events.listen(events.add);
  try {
    await tts.initialize();
    await tts.speak('utt-1', '你好，我是小鲸');
    await tts.speak('utt-2', '这是第二句');
    stdout.writeln('events: ${events.map((SpeechOutputEvent e) => e.toString()).toList()}');
    final bool ok = events
            .where((SpeechOutputEvent e) =>
                e.kind == SpeechOutputEventKind.finished)
            .length ==
        2;
    stdout.writeln(ok ? 'PASS (2 utterances)' : 'FAIL');
    exitCode = ok ? 0 : 1;
  } catch (error) {
    stdout.writeln('FAIL: $error');
    exitCode = 2;
  } finally {
    await sub.cancel();
    await tts.dispose();
  }
}
