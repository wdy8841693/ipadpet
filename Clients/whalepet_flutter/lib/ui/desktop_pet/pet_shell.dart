import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../../core/pet/pet_state.dart';
import 'chat_panel.dart';
import 'pet_assets.dart';
import 'pet_bubble.dart';
import 'pet_layout.dart';
import 'pet_menu.dart';
import 'pet_runtime.dart';
import 'settings_panel.dart';

/// 桌宠主界面：一块固定大小的透明窗口里，摆气泡、宠物、面板和菜单。
///
/// 画面全部来自 `PetRuntime`（ChangeNotifier），这里只做「摆位置 + 转发动作」。
class PetShell extends StatefulWidget {
  const PetShell({super.key, required this.runtime});

  final PetRuntime runtime;

  @override
  State<PetShell> createState() => _PetShellState();
}

class _PetShellState extends State<PetShell> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await widget.runtime.persistNow();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _quit() async {
    await widget.runtime.persistNow();
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.runtime,
      builder: (BuildContext context, Widget? _) {
        final PetRuntime runtime = widget.runtime;
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: <Widget>[
              if (runtime.panel == PetPanel.chat)
                Positioned.fromRect(
                  rect: PetLayout.panelRect,
                  child: ChatPanel(
                    runtime: runtime,
                    onClose: runtime.closePanel,
                    onOpenSettings: () => runtime.openPanel(PetPanel.settings),
                  ),
                ),
              if (runtime.panel == PetPanel.settings)
                Positioned.fromRect(
                  rect: PetLayout.panelRect,
                  child: SettingsPanel(
                    runtime: runtime,
                    onClose: runtime.closePanel,
                    onOpenChat: () => runtime.openPanel(PetPanel.chat),
                  ),
                ),
              if (runtime.menuOpen)
                Positioned.fromRect(
                  rect: PetLayout.menuRect,
                  child: PetMenu(
                    runtime: runtime,
                    onOpenChat: () => runtime.openPanel(PetPanel.chat),
                    onOpenSettings: () => runtime.openPanel(PetPanel.settings),
                    onQuit: _quit,
                  ),
                ),
              if (runtime.bubbleText != null)
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: PetLayout.windowHeight - PetLayout.petRect.top + 2,
                  child: Center(
                    child: PetBubble(
                      text: runtime.bubbleText!,
                      maxWidth: PetLayout.windowWidth - 48,
                    ),
                  ),
                ),
              Positioned.fromRect(
                rect: PetLayout.petRect,
                child: _PetFigure(runtime: runtime),
              ),
              Positioned(
                left: PetLayout.petRect.left + 20,
                width: PetLayout.petSize - 40,
                top: PetLayout.petRect.bottom + 2,
                child: _VitalsBar(runtime: runtime),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 宠物本体：立绘 + 程序化运动（和 iPad 的 SpriteKit 版本同一套思路）。
class _PetFigure extends StatelessWidget {
  const _PetFigure({required this.runtime});

  final PetRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final PetState state = runtime.petState;
    final double t = runtime.elapsedSeconds;
    final bool flip = state == PetState.walk && runtime.walkDirection < 0;
    final bool hungry = runtime.vitals.satiety < 25;

    double dy = 0;
    double dx = 0;
    double scaleX = 1;
    double scaleY = 1;
    double rotation = 0;

    switch (state) {
      case PetState.idle:
        dy = sin(t * 1.8) * 2.5;
      case PetState.walk:
        dy = sin(t * 6.0).abs() * -3;
      case PetState.swim:
        dx = sin(t * 1.2) * 6;
        dy = cos(t * 1.2) * 4;
        rotation = sin(t * 1.2) * 0.02;
      case PetState.sleep:
        scaleY = 1 + sin(t * 1.0) * 0.012;
        dy = 2;
      case PetState.happy:
        dy = sin(t * 9.0).abs() * -5;
      case PetState.eat:
        scaleY = 1 + sin(t * 10.0) * 0.02;
      case PetState.play:
        rotation = sin(t * 4.0) * 0.05;
        dy = sin(t * 8.0).abs() * -4;
      case PetState.drag:
        rotation = sin(t * 6.0) * 0.06;
      case PetState.listening:
        dy = sin(t * 3.0) * 2;
      case PetState.thinking:
        dy = sin(t * 2.2) * 3;
        rotation = sin(t * 1.1) * 0.03;
      case PetState.speaking:
        scaleY = 1 + sin(t * 7.0) * 0.015;
    }

    if (flip) scaleX = -1;

    final String asset = petAssetForVitals(state, hungry: hungry, sad: runtime.vitals.mood < 30);

    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          runtime.closeMenu();
          runtime.petHead();
        },
        onDoubleTap: () => runtime.openPanel(PetPanel.chat),
        onSecondaryTapDown: (TapDownDetails _) => runtime.toggleMenu(),
        onPanStart: (DragStartDetails _) => runtime.beginDrag(),
        onPanEnd: (DragEndDetails _) => runtime.endDrag(),
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: <Widget>[
            // 地面投影：让透明窗口里的宠物「有重量」。
            Positioned(
              bottom: 6,
              child: Container(
                width: 110,
                height: 16,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[Color(0x4400A8D0), Color(0x0000A8D0)],
                  ),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(dx, dy),
              child: Transform.rotate(
                angle: rotation,
                child: Transform(
                  transform: Matrix4.diagonal3Values(scaleX, scaleY, 1),
                  alignment: Alignment.center,
                  child: Image.asset(
                    asset,
                    width: PetLayout.petSize,
                    height: PetLayout.petSize,
                    filterQuality: FilterQuality.medium,
                    isAntiAlias: true,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            if (state == PetState.sleep)
              Positioned(
                right: 26,
                top: 18,
                child: _SleepingZ(phase: t),
              ),
          ],
        ),
      ),
    );
  }
}

class _SleepingZ extends StatelessWidget {
  const _SleepingZ({required this.phase});

  final double phase;

  @override
  Widget build(BuildContext context) {
    final double shift = (phase * 12) % 20;
    return Transform.translate(
      offset: Offset(0, -shift),
      child: Opacity(
        opacity: (1 - shift / 20).clamp(0.0, 1.0),
        child: const Text(
          'z',
          style: TextStyle(
            color: Color(0x99CFEFFF),
            fontSize: 16,
            fontWeight: FontWeight.w600,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// 三条细小的数值条：饱食 / 心情 / 精力。
class _VitalsBar extends StatelessWidget {
  const _VitalsBar({required this.runtime});

  final PetRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final double satiety = runtime.vitals.satiety;
    final double mood = runtime.vitals.mood;
    final double energy = runtime.vitals.energy;
    return Opacity(
      opacity: 0.75,
      child: Row(
        children: <Widget>[
          Expanded(child: _Bar(value: satiety, color: const Color(0xFFF2B25C))),
          const SizedBox(width: 3),
          Expanded(child: _Bar(value: mood, color: const Color(0xFFFF8FA8))),
          const SizedBox(width: 3),
          Expanded(child: _Bar(value: energy, color: const Color(0xFF63D6FF))),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color});

  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        height: 3,
        color: const Color(0x33001122),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: (value / 100).clamp(0.0, 1.0),
          child: ColoredBox(color: color),
        ),
      ),
    );
  }
}
