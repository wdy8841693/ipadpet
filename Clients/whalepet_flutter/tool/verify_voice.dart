// 开发验证工具：在没有麦克风的机器上，用 WAV 输入验证本地语音引擎。
//
// 用法：
//   dart run tool/verify_voice.dart wake   <wav 路径>
//   dart run tool/verify_voice.dart listen <wav 路径>
//
// 引擎会走与正式运行完全相同的 PowerShell 脚本、唤醒语法与状态切换，
// 只是把「默认麦克风」换成 `SetInputToWaveFile`（SapiVoiceEngine 的 audioFile）。
//
// 退出码：收到期望事件为 0，超时或引擎报错非 0。

import 'dart:async';
import 'dart:io';

import '../lib/core/voice/voice_engine.dart';
import '../lib/platform/voice/sapi_voice_engine.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2 || !<String>['wake', 'listen'].contains(args[0])) {
    stderr.writeln('用法: dart run tool/verify_voice.dart wake|listen <wav 路径>');
    exitCode = 64;
    return;
  }
  final String mode = args[0];
  final File wav = File(args[1]);
  if (!await wav.exists()) {
    stderr.writeln('WAV 不存在：${wav.path}');
    exitCode = 66;
    return;
  }

  final SapiVoiceEngine engine = SapiVoiceEngine(audioFile: wav.path);
  final Completer<bool> done = Completer<bool>();
  bool success = false;
  final StreamSubscription<VoiceEngineEvent> sub =
      engine.events.listen((VoiceEngineEvent event) {
    stdout.writeln('EVENT ${event.runtimeType}: $event');
    if (mode == 'wake' && event is VoiceWakeDetectedEvent) success = true;
    if (mode == 'listen' && event is VoiceFinalTranscriptEvent) success = true;
    if (event is VoiceCaptureErrorEvent) {
      stdout.writeln('ENGINE ERROR: ${event.code} ${event.message}');
      if (!done.isCompleted) done.complete(false);
    }
    if (success && !done.isCompleted) done.complete(true);
  });

  try {
    await engine.initialize(const VoiceEngineConfig());
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mode == 'wake') {
      await engine.startWakeListening();
    } else {
      await engine.startManualListening();
    }
    final bool ok = await done.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => false,
    );
    stdout.writeln(ok ? 'PASS ($mode)' : 'FAIL ($mode): 没有收到期望事件');
    exitCode = ok ? 0 : 1;
  } catch (error) {
    stdout.writeln('FAIL ($mode): $error');
    exitCode = 2;
  } finally {
    await sub.cancel();
    await engine.dispose();
  }
}
