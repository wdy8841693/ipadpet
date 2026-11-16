import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/material.dart';

import '../../core/pet/pet_state.dart';
import '../desktop_pet/chat_panel.dart';
import '../desktop_pet/pet_assets.dart';
import '../desktop_pet/pet_bubble.dart';
import '../desktop_pet/settings_panel.dart';
import '../pet_ui_model.dart';
import 'mobile_pet_runtime.dart';

/// Android 全屏场景（§6.3：移动端是「屏幕坐标系内的场景」，不是透明桌宠窗口）。
///
/// 画面上半部是海底世界 + 宠物 + 气泡，顶部是状态条，底部是操作按钮；
/// 聊天/设置面板做成场景内的浮层，复用桌面端的 [ChatPanel] / [SettingsPanel]。
class MobilePetShell extends StatefulWidget {
  const MobilePetShell({super.key, required this.runtime});

  final MobilePetRuntime runtime;

  @override
  State<MobilePetShell> createState() => _MobilePetShellState();
}

class _MobilePetShellState extends State<MobilePetShell>
    with WidgetsBindingObserver {
  final GlobalKey _sceneKey = GlobalKey();
  double _dragGrabDy = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        widget.runtime.handleForeground();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        widget.runtime.handleBackground();
      case AppLifecycleState.inactive:
        break;
    }
  }

  Offset? _toScene(Offset global) {
    final RenderObject? box = _sceneKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return null;
    final Offset local = box.globalToLocal(global);
    if (local.dx.isNaN || local.dy.isNaN) return null;
    return local;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.runtime,
      builder: (BuildContext context, Widget? _) {
        final MobilePetRuntime runtime = widget.runtime;
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size size = Size(constraints.maxWidth, constraints.maxHeight);
            runtime.updateSceneSize(size);
            final double petSize =
                (size.width * 0.62).clamp(150.0, 260.0).toDouble();
            return Scaffold(
              backgroundColor: const Color(0xFF071C30),
              body: Stack(
                key: _sceneKey,
                children: <Widget>[
                  _SeaBackground(size: size),
                  _Bubbles(size: size, elapsed: runtime.elapsedSeconds),
                  _buildPet(runtime, petSize),
                  if (runtime.bubbleText != null)
                    _buildBubble(runtime, size, petSize),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: SafeArea(
                      bottom: false,
                      child: _VitalsHud(runtime: runtime),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      child: _ActionBar(runtime: runtime),
                    ),
                  ),
                  if (runtime.panel != PetPanel.none)
                    _PanelHost(
                      runtime: runtime,
                      panel: runtime.panel,
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPet(MobilePetRuntime runtime, double petSize) {
    final Size scene = runtime.sceneSize;
    final double feetY = runtime.petPosition.dy;
    final double left = (runtime.petPosition.dx - petSize / 2)
        .clamp(0.0, math.max(scene.width - petSize, 0.0))
        .toDouble();
    final double top = feetY - petSize;
    final bool facesLeft =
        petFacesLeft(runtime.petState, runtime.walkDirection);
    final String asset = petAssetForVitals(
      runtime.petState,
      hungry: runtime.vitals.isHungry,
      sad: runtime.vitals.mood < 25,
    );

    return Positioned(
      left: left,
      top: top,
      width: petSize,
      height: petSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: runtime.petHead,
        onPanStart: (DragStartDetails details) {
          final Offset? scenePos = _toScene(details.globalPosition);
          _dragGrabDy = scenePos == null ? 0 : runtime.petPosition.dy - scenePos.dy;
          runtime.beginDrag();
        },
        onPanUpdate: (DragUpdateDetails details) {
          final Offset? scenePos = _toScene(details.globalPosition);
          if (scenePos == null) return;
          runtime.dragTo(Offset(scenePos.dx, scenePos.dy + _dragGrabDy));
        },
        onPanEnd: (_) => runtime.endDrag(),
        onPanCancel: runtime.endDrag,
        child: _PetSprite(
          asset: asset,
          state: runtime.petState,
          elapsed: runtime.elapsedSeconds,
          facesLeft: facesLeft,
        ),
      ),
    );
  }

  Widget _buildBubble(
    MobilePetRuntime runtime,
    Size scene,
    double petSize,
  ) {
    final double feetY = runtime.petPosition.dy;
    final double petTop = feetY - petSize;
    final bool above = petTop > 120;
    final double maxWidth = math.min(300.0, scene.width - 40);

    return Positioned(
      left: 16,
      right: 16,
      top: above ? null : petTop + petSize * 0.82,
      bottom: above ? (scene.height - petTop + 6) : null,
      child: Center(
        child: PetBubble(
          key: ValueKey<String>(runtime.bubbleText!),
          text: runtime.bubbleText!,
          maxWidth: maxWidth,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 背景 / 气泡

class _SeaBackground extends StatelessWidget {
  const _SeaBackground({required this.size});

  final Size size;

  @override
  Widget build(BuildContext context) {
    final double floorTop = size.height * 0.84;
    return Stack(
      children: <Widget>[
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0xFF0A2A4A),
                  Color(0xFF0E3C63),
                  Color(0xFF12507D),
                  Color(0xFF1A6A9B),
                ],
              ),
            ),
          ),
        ),
        // 海面光斑
        Positioned(
          left: -60,
          right: -60,
          top: -80,
          height: size.height * 0.5,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.6),
                radius: 1.1,
                colors: <Color>[
                  const Color(0x408FE8FF),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // 海底沙地
        Positioned(
          left: 0,
          right: 0,
          top: floorTop,
          bottom: 0,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0xFFE8D6A8), Color(0xFFC9AF7A)],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: floorTop - 3,
          height: 3,
          child: const DecoratedBox(
            decoration: BoxDecoration(color: Color(0x66FFF6D8)),
          ),
        ),
      ],
    );
  }
}

class _Bubbles extends StatelessWidget {
  const _Bubbles({required this.size, required this.elapsed});

  final Size size;
  final double elapsed;

  @override
  Widget build(BuildContext context) {
    if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
    final List<Widget> items = <Widget>[];
    for (int i = 0; i < 10; i++) {
      final double speed = 14 + (i % 4) * 7; // px/s
      final double startX = ((i * 97) % 100) / 100 * size.width;
      final double radius = 2.5 + (i % 3) * 2.5;
      final double travel = (elapsed * speed + i * 130) % (size.height + 80);
      final double y = size.height - travel;
      items.add(Positioned(
        left: startX,
        top: y,
        child: Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0x14FFFFFF),
            border: Border.all(color: const Color(0x59FFFFFF), width: 1),
          ),
        ),
      ));
    }
    return IgnorePointer(child: Stack(children: items));
  }
}

// ---------------------------------------------------------------- 宠物立绘

class _PetSprite extends StatelessWidget {
  const _PetSprite({
    required this.asset,
    required this.state,
    required this.elapsed,
    required this.facesLeft,
  });

  final String asset;
  final PetState state;
  final double elapsed;
  final bool facesLeft;

  @override
  Widget build(BuildContext context) {
    final _Motion motion = _Motion.of(state, elapsed);
    Widget sprite = Image.asset(
      asset,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
    );
    sprite = Transform.scale(
      scaleX: facesLeft ? -motion.sx : motion.sx,
      scaleY: motion.sy,
      child: sprite,
    );
    sprite = Transform.rotate(angle: motion.rot, child: sprite);
    sprite = Transform.translate(offset: Offset(0, -motion.dy), child: sprite);
    return sprite;
  }
}

/// 各状态的程序化运动参数（对应 iPad 版 `PetNode` 的 SKAction 编排）。
class _Motion {
  const _Motion({
    required this.dy,
    required this.rot,
    required this.sx,
    required this.sy,
  });

  final double dy;
  final double rot;
  final double sx;
  final double sy;

  static const double _twoPi = math.pi * 2;

  static _Motion of(PetState state, double t) {
    double dy = 0;
    double rot = 0;
    double sx = 1;
    double sy = 1;

    double bob(double period, double amplitude) =>
        amplitude * (1 - math.cos(_twoPi * t / period)) / 2;
    double sway(double period, double amplitude) =>
        amplitude * math.sin(_twoPi * t / period);
    double breath(double halfPeriod) =>
        1 + 0.006 * (1 - math.cos(math.pi * t / halfPeriod));
    double bounce(double period, double height) {
      final double phase = (t % period) / period;
      return height * math.sin(math.pi * phase);
    }

    switch (state) {
      case PetState.idle:
        dy = bob(2.6, 5);
        sy = breath(1.5);
      case PetState.walk:
        dy = bob(0.55, 4);
        rot = sway(0.55, 0.05);
      case PetState.swim:
        dy = bob(1.8, 12);
        rot = sway(1.8, 0.10);
      case PetState.happy:
        dy = bounce(0.5, 16);
        final double s = math.sin(_twoPi * t / 0.5);
        sx = 1 + 0.03 * s;
        sy = 1 - 0.03 * s;
      case PetState.eat:
        rot = 0.04 * math.sin(_twoPi * t / 0.44).abs();
      case PetState.sleep:
        dy = bob(3.4, 2.5);
        sy = breath(2.2);
      case PetState.drag:
        rot = sway(0.6, 0.12);
      case PetState.play:
        dy = bounce(0.55, 20);
        rot = sway(0.55, 0.12);
      case PetState.listening:
        dy = bob(1.2, 8);
        sy = breath(1.5);
      case PetState.thinking:
        dy = bob(2.0, 4);
        rot = sway(2.0, 0.06);
      case PetState.speaking:
        dy = bob(0.8, 6);
        sy = breath(1.5);
    }
    return _Motion(dy: dy, rot: rot, sx: sx, sy: sy);
  }
}

// ---------------------------------------------------------------- 顶部 / 底部

class _VitalsHud extends StatelessWidget {
  const _VitalsHud({required this.runtime});

  final MobilePetRuntime runtime;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _VitalBar(
                emoji: '🍣',
                value: runtime.vitals.satiety,
                color: const Color(0xFFFF9E59),
              ),
              const SizedBox(height: 6),
              _VitalBar(
                emoji: '💙',
                value: runtime.vitals.mood,
                color: const Color(0xFF73BFFF),
              ),
              const SizedBox(height: 6),
              _VitalBar(
                emoji: '⚡️',
                value: runtime.vitals.energy,
                color: const Color(0xFFFFD966),
              ),
            ],
          ),
          const Spacer(),
          GestureDetector(
            onTap: () => runtime.openPanel(PetPanel.settings),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0x66000000),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0x4DFFFFFF)),
              ),
              child: Text(
                '${runtime.petName} · ${runtime.connectionLabel} · ${runtime.voiceStateLabel}',
                style: const TextStyle(
                  color: Color(0xFFE6F7FF),
                  fontSize: 11,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VitalBar extends StatelessWidget {
  const _VitalBar({
    required this.emoji,
    required this.value,
    required this.color,
  });

  final String emoji;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(emoji, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 6),
        SizedBox(
          width: 86,
          height: 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              children: <Widget>[
                const Positioned.fill(
                  child: ColoredBox(color: Color(0x2EFFFFFF)),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: (86 * value / 100).clamp(4.0, 86.0),
                  child: ColoredBox(color: color),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.runtime});

  final MobilePetRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final bool sleeping = runtime.petState == PetState.sleep;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x59000000),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Row(
        children: <Widget>[
          _ActionButton(
            icon: Icons.set_meal,
            label: '投喂',
            onTap: runtime.feed,
          ),
          _ActionButton(
            icon: Icons.bubble_chart,
            label: '玩耍',
            onTap: runtime.play,
          ),
          _ActionButton(
            icon: sleeping ? Icons.wb_sunny : Icons.nightlight_round,
            label: sleeping ? '叫醒' : '睡觉',
            onTap: runtime.toggleSleep,
          ),
          _ActionButton(
            icon: runtime.voiceEnabled ? Icons.mic : Icons.mic_none,
            label: '说话',
            highlighted: runtime.voiceEnabled,
            onTap: runtime.manualListen,
          ),
          _ActionButton(
            icon: Icons.forum,
            label: '聊天',
            onTap: () => runtime.openPanel(PetPanel.chat),
          ),
          _ActionButton(
            icon: Icons.settings,
            label: '设置',
            onTap: () => runtime.openPanel(PetPanel.settings),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkResponse(
        onTap: onTap,
        radius: 30,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: highlighted
                    ? const Color(0xFF7FE3FF)
                    : const Color(0xEBFFFFFF),
                border: Border.all(color: const Color(0xFF598CBF), width: 1.5),
              ),
              child: Icon(
                icon,
                size: 21,
                color: highlighted
                    ? const Color(0xFF06263F)
                    : const Color(0xFF21476B),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xE6FFFFFF),
                fontSize: 11,
                decoration: TextDecoration.none,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 面板浮层

class _PanelHost extends StatelessWidget {
  const _PanelHost({required this.runtime, required this.panel});

  final MobilePetRuntime runtime;
  final PetPanel panel;

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final double width = math.min(screen.width - 20, 460);
    final double height = math.min(screen.height - 120, 620);
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onTap: runtime.closePanel,
              child: const ColoredBox(color: Color(0x99000000)),
            ),
          ),
          Center(
            child: SizedBox(
              width: width,
              height: height,
              child: Material(
                color: Colors.transparent,
                child: panel == PetPanel.chat
                    ? ChatPanel(
                        runtime: runtime,
                        onClose: runtime.closePanel,
                        onOpenSettings: () =>
                            runtime.openPanel(PetPanel.settings),
                      )
                    : SettingsPanel(
                        runtime: runtime,
                        desktopOptions: false,
                        onClose: runtime.closePanel,
                        onOpenChat: () => runtime.openPanel(PetPanel.chat),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
