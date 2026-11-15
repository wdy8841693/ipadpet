import 'package:flutter/material.dart';

/// 宠物头顶的对话气泡（桌宠版：半透明深色卡片 + 小尾巴）。
///
/// 与 iPad 的 `SpeechBubbleNode` 同一套文案来源，但这里限制最大行数，
/// 避免长回答把窗口撑出屏幕 —— 完整回答在聊天面板里看。
class PetBubble extends StatelessWidget {
  const PetBubble({
    super.key,
    required this.text,
    required this.maxWidth,
  });

  final String text;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xE6112A45),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x5548D6F5), width: 1),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x3300B4D8),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Text(
              text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFE6F7FF),
                fontSize: 13,
                height: 1.45,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          // 小尾巴
          Transform.translate(
            offset: const Offset(0, -1),
            child: CustomPaint(
              size: const Size(16, 9),
              painter: _BubbleTailPainter(),
            ),
          ),
        ],
      ),
    );
  }
}

class _BubbleTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint fill = Paint()..color = const Color(0xE6112A45);
    final Path path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
