import 'package:flutter/material.dart';

import 'pet_runtime.dart';
import 'pet_theme.dart';

/// 右键菜单（桌宠没有标题栏，所有入口都收在这里）。
class PetMenu extends StatelessWidget {
  const PetMenu({
    super.key,
    required this.runtime,
    required this.onOpenChat,
    required this.onOpenSettings,
    required this.onQuit,
  });

  final PetRuntime runtime;
  final VoidCallback onOpenChat;
  final VoidCallback onOpenSettings;
  final VoidCallback onQuit;

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _MenuItem(
            icon: Icons.back_hand_outlined,
            label: '摸摸头',
            onTap: runtime.petHead,
          ),
          _MenuItem(
            icon: Icons.set_meal_outlined,
            label: '投喂小鱼干',
            onTap: runtime.feed,
          ),
          _MenuItem(
            icon: Icons.sports_baseball_outlined,
            label: '一起玩',
            onTap: runtime.play,
          ),
          const Divider(height: 8, color: Color(0x2248D6F5)),
          _MenuItem(
            icon: Icons.chat_bubble_outline,
            label: '说点什么…',
            onTap: onOpenChat,
          ),
          _MenuItem(
            icon: Icons.settings_outlined,
            label: '设置',
            onTap: onOpenSettings,
          ),
          _MenuItem(
            icon: Icons.bedtime_outlined,
            label: runtime.petState.name == 'sleep' ? '叫醒它' : '让它睡觉',
            onTap: runtime.toggleSleep,
          ),
          const Divider(height: 8, color: Color(0x2248D6F5)),
          _MenuItem(
            icon: Icons.logout,
            label: '退出',
            danger: true,
            onTap: onQuit,
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final Color color = danger ? const Color(0xFFFF9E8C) : const Color(0xFFD8F2FF);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5.5),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
