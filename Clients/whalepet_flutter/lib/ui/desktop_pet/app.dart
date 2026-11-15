import 'package:flutter/material.dart';

import 'pet_runtime.dart';
import 'pet_shell.dart';

/// 应用外壳。
///
/// 刻意只有一个 `Scaffold` + 透明背景：整个窗口就是「一层透明玻璃上摆宠物」，
/// 不要再套 Navigator / 页面路由 —— 桌宠没有「页面」，面板都是窗口内的浮层。
class WhalePetApp extends StatelessWidget {
  const WhalePetApp({super.key, required this.runtime});

  final PetRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '鲸鱼娘',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
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
      home: PetShell(runtime: runtime),
    );
  }
}
