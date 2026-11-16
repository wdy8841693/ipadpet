import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/config/app_paths.dart';
import 'core/platform/desktop_window.dart';
import 'core/voice/speech_output.dart';
import 'core/voice/voice_engine.dart';
import 'platform/android/native_bridge.dart';
import 'platform/desktop_window/win32_window.dart';
import 'platform/secure_storage/keystore_token_store.dart';
import 'platform/speech_output/android_system_tts.dart';
import 'platform/speech_output/powershell_speech.dart';
import 'platform/voice/android_system_voice_engine.dart';
import 'platform/voice/sapi_voice_engine.dart';
import 'ui/desktop_pet/app.dart';
import 'ui/desktop_pet/pet_runtime.dart';
import 'ui/mobile_scene/mobile_app.dart';
import 'ui/mobile_scene/mobile_pet_runtime.dart';

/// 跨平台入口：同一份 `core/`，按平台装配不同的适配层（§3.3）。
///
/// | 平台 | 场景 | 语音引擎 | 播报 | 令牌存储 |
/// |---|---|---|---|---|
/// | Android | `ui/mobile_scene`（全屏场景） | 系统 SpeechRecognizer | 系统 TTS | Keystore |
/// | Windows | `ui/desktop_pet`（透明窗口） | SAPI 语法 | SAPI | DPAPI |
/// | 其它 | 桌面壳 + 空实现（仅开发/测试） | — | — | 明文 |
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await _runAndroid();
    return;
  }
  await _runDesktop();
}

Future<void> _runAndroid() async {
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  final String root = await NativeBridge.appRootDir();
  final AppPaths paths = AppPaths(
    rootDirectory: Directory(root.isEmpty ? Directory.systemTemp.path : root),
  );

  final MobilePetRuntime runtime = MobilePetRuntime(
    paths: paths,
    speech: AndroidSystemTts(),
    voiceEngine: AndroidSystemVoiceEngine(),
    tokenStorage: const KeystoreTokenStore(),
  );
  // 先准备好配置/存档/客户端 id，再画第一帧；TTS 与网络连接放到 runApp 之后。
  await runtime.start();
  runApp(MobilePetApp(runtime: runtime));
  unawaited(runtime.startServices());
}

Future<void> _runDesktop() async {
  final AppPaths paths = AppPaths.resolve();
  final DesktopWindowAdapter window = Platform.isWindows
      ? Win32DesktopWindow()
      : const NoopDesktopWindow();
  final SpeechOutputAdapter speech = Platform.isWindows
      ? PowerShellSpeechOutput()
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
  await runtime.start();

  runApp(WhalePetApp(runtime: runtime));

  unawaited(runtime.startServices());
}
