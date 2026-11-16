import 'package:flutter/material.dart';

/// 桌面面板共用的半透明卡片样式（和气泡同一套配色）。
class PanelCard extends StatelessWidget {
  const PanelCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding ?? const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xF00B1F33),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x5548D6F5)),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x4400B4D8),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 统一的文字样式（桌面面板里到处都要写 color，抽出来避免漏）。
const TextStyle kPanelLabelStyle = TextStyle(
  color: Color(0x99CFEFFF),
  fontSize: 11,
  height: 1.3,
);

const TextStyle kPanelValueStyle = TextStyle(
  color: Color(0xFFEAF9FF),
  fontSize: 12.5,
  height: 1.4,
);

const TextStyle kPanelTitleStyle = TextStyle(
  color: Color(0xFFE6F7FF),
  fontSize: 14,
  fontWeight: FontWeight.w600,
);
