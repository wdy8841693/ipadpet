import 'package:flutter/material.dart';

import 'mobile_pet_runtime.dart';
import 'mobile_shell.dart';

/// Android 应用外壳。
///
/// 与桌面壳的区别：这里是一块**不透明的全屏场景**（海底世界），而不是透明玻璃窗口；
/// 所以主题要给出实色背景，其余（气泡、面板、状态条）与桌面共用组件。
class MobilePetApp extends StatelessWidget {
  const MobilePetApp({super.key, required this.runtime});

  final MobilePetRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '鲸鱼娘',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF071C30),
        canvasColor: const Color(0xFF0B2237),
        splashFactory: NoSplash.splashFactory,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF7FE3FF),
          secondary: Color(0xFF63D6FF),
          surface: Color(0xFF0B1F33),
        ),
        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Color(0xFF7FE3FF),
          selectionColor: Color(0x5548D6F5),
          selectionHandleColor: Color(0xFF7FE3FF),
        ),
      ),
      home: MobilePetShell(runtime: runtime),
    );
  }
}
