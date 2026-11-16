import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/config/app_paths.dart';
import 'core/platform/desktop_window.dart';
import 'core/voice/speech_output.dart';
import 'core/voice/voice_engine.dart';
import 'platform/desktop_window/macos_window.dart';
import 'platform/desktop_window/win32_window.dart';
import 'platform/speech_output/macos_speech.dart';
import 'platform/speech_output/powershell_speech.dart';
import 'platform/voice/sapi_voice_engine.dart';
import 'ui/desktop_pet/app.dart';
import 'ui/desktop_pet/pet_runtime.dart';

/// 桌宠入口（阶段 E：Windows / macOS）。
///
/// 平台能力全部通过适配层注入，`core/` 与 `ui/` 不直接碰平台 API：
///   - `DesktopWindowAdapter` → `Win32DesktopWindow` / `MacOSDesktopWindow`
///     （透明置顶、穿透、原生拖拽；macOS 走 MethodChannel + 原生 AppKit）；
///   - `SpeechOutputAdapter` → `PowerShellSpeechOutput`（SAPI）/
///     `MacOSSpeechOutput`（AVSpeechSynthesizer）；
///   - 语音引擎目前只有 Windows 的 SAPI 实现，macOS v1 用空实现
///     （文字对话可用，语音入口状态显示「语音关闭」）。
///
/// 其它平台跑起来是「空实现 + 宠物逻辑」，用于开发和测试 UI。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppPaths paths = AppPaths.resolve();
  final DesktopWindowAdapter window = Platform.isWindows
      ? Win32DesktopWindow()
      : Platform.isMacOS
          ? MacOSDesktopWindow()
          : const NoopDesktopWindow();
  final SpeechOutputAdapter speech = Platform.isWindows
      ? PowerShellSpeechOutput()
      : Platform.isMacOS
          ? MacOSSpeechOutput()
          : const NoopSpeechOutput();

  // 开发验证钩子：设置环境变量 WHALEPET_VOICE_WAV 指向一段 WAV，
  // 引擎就用 SetInputToWaveFile 代替麦克风，可在无麦克风的机器上跑通全链路。
  final String? voiceWav = Platform.environment['WHALEPET_VOICE_WAV'];
  final VoiceEngineAdapter voiceEngine = Platform.isWindows
      ? SapiVoiceEngine(audioFile: voiceWav)
      : const NoopVoiceEngine();

  final PetRuntime runtime = PetRuntime(
    paths: paths,
    window: window,
    speech: speech,
    voiceEngine: voiceEngine,
  );
  // 先准备好配置/存档/窗口，再画第一帧；耗时的 TTS 与网络连接放到 runApp 之后。
  await runtime.start();

  runApp(WhalePetApp(runtime: runtime));

  unawaited(runtime.startServices());

  // 开发自检钩子：WHALEPET_SPEAK_TEST=1 时启动后播一句并把播报事件打到 stdout，
  // 用来在没有 UI 交互的情况下验证 macOS 的 AVSpeechSynthesizer 通道。
  if (Platform.environment['WHALEPET_SPEAK_TEST'] != null) {
    unawaited(() async {
      speech.events.listen((event) => debugPrint('speech event: $event'));
      try {
        await speech.initialize();
        await speech.speak('boot-selftest', '鲸鱼娘语音通道自检，听到这句话就说明播报正常。');
        debugPrint('speech selftest: speaking');
      } catch (error) {
        debugPrint('speech selftest failed: $error');
      }
    }());
  }

  // 开发自检钩子：WHALEPET_CHAT_TEST="你好" 时启动后自动发一条文本命令，
  // 用于无人值守验证「命令 → 回答 → 气泡」这条链路（配合 mock /api/agent）。
  final String? chatProbe = Platform.environment['WHALEPET_CHAT_TEST'];
  if (chatProbe != null && chatProbe.trim().isNotEmpty) {
    unawaited(() async {
      await Future<void>.delayed(const Duration(seconds: 3));
      try {
        await runtime.sendText(chatProbe);
        debugPrint('chat selftest: sent "$chatProbe"');
      } catch (error) {
        debugPrint('chat selftest failed: $error');
      }
    }());
  }

  // macOS：原生层在 applicationWillTerminate 时通知 Dart 尽快落盘存档
  // （平时有 15 秒节流保存兜底，这里只是把最后一段窗口期补上）。
  const MethodChannel lifecycleChannel = MethodChannel('whalepet/lifecycle');
  lifecycleChannel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'terminating') {
      await runtime.persistNow();
    }
    return null;
  });
}
