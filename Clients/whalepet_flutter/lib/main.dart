import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/config/app_paths.dart';
import 'core/platform/desktop_window.dart';
import 'core/voice/speech_output.dart';
import 'platform/desktop_window/win32_window.dart';
import 'platform/speech_output/powershell_speech.dart';
import 'ui/desktop_pet/app.dart';
import 'ui/desktop_pet/pet_runtime.dart';

/// Windows 桌宠入口（阶段 E）。
///
/// 平台能力全部通过适配层注入，`core/` 与 `ui/` 不直接 import Win32：
///   - `DesktopWindowAdapter` → `Win32DesktopWindow`（透明置顶、穿透、原生拖拽）；
///   - `SpeechOutputAdapter` → `PowerShellSpeechOutput`（系统 SAPI 播报）。
///
/// 非 Windows 平台跑起来是「空实现 + 宠物逻辑」，用于开发和测试 UI。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final AppPaths paths = AppPaths.resolve();
  final DesktopWindowAdapter window = Platform.isWindows
      ? Win32DesktopWindow()
      : const NoopDesktopWindow();
  final SpeechOutputAdapter speech = Platform.isWindows
      ? PowerShellSpeechOutput()
      : const NoopSpeechOutput();

  final PetRuntime runtime = PetRuntime(
    paths: paths,
    window: window,
    speech: speech,
  );
  // 先准备好配置/存档/窗口，再画第一帧；耗时的 TTS 与网络连接放到 runApp 之后。
  await runtime.start();

  runApp(WhalePetApp(runtime: runtime));

  unawaited(runtime.startServices());
}
