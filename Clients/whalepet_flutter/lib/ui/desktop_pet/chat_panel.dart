import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'pet_runtime.dart';
import 'pet_theme.dart';

/// 聊天面板：和 DSH 说话的地方（桌面端没有麦克风时的主要入口）。
class ChatPanel extends StatefulWidget {
  const ChatPanel({
    super.key,
    required this.runtime,
    required this.onOpenSettings,
    required this.onClose,
  });

  final PetRuntime runtime;
  final VoidCallback onOpenSettings;
  final VoidCallback onClose;

  @override
  State<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends State<ChatPanel> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }


  Future<void> _send() async {
    final String text = _controller.text;
    if (text.trim().isEmpty) return;
    _controller.clear();
    await widget.runtime.sendText(text);
    _focusNode.requestFocus();
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<ChatMessage> messages = widget.runtime.chat.reversed.toList();
    final bool connected = widget.runtime.isConnected;
    // 没有标题栏，Esc 收起面板（用 Shortcuts 而不是 Focus.onKeyEvent：
    // TextField 聚焦时 ESC 会先被文本输入层吃掉）。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
      },
      child: PanelCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    '和小鲸说话',
                    style: TextStyle(
                      color: Color(0xFFE6F7FF),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _StatusDot(label: widget.runtime.connectionLabel, ok: connected),
                IconButton(
                  tooltip: '设置',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: const Color(0xFF9FD8F0),
                  onPressed: widget.onOpenSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
                IconButton(
                  tooltip: '关闭',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: const Color(0xFF9FD8F0),
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Text(
                        '说点什么吧，比如「今天有什么安排」',
                        style: TextStyle(color: Color(0x88CFEFFF), fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      padding: const EdgeInsets.only(right: 4),
                      itemCount: messages.length,
                      itemBuilder: (BuildContext context, int index) {
                        final ChatMessage message = messages[index];
                        return _MessageRow(message: message);
                      },
                    ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    autofocus: true,
                    maxLines: 3,
                    minLines: 1,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (String _) => _send(),
                    style: const TextStyle(color: Color(0xFFEAF9FF), fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: connected ? '输入指令，Enter 发送' : '还没连上，先去设置填地址和令牌',
                      hintStyle: const TextStyle(color: Color(0x66CFEFFF), fontSize: 12),
                      filled: true,
                      fillColor: const Color(0x33102A45),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0x3348D6F5)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0x3348D6F5)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: Color(0x8848D6F5)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '发送',
                  onPressed: _send,
                  color: const Color(0xFF7FE3FF),
                  icon: const Icon(Icons.send_rounded, size: 20),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final bool fromUser = message.fromUser;
    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: fromUser ? const Color(0x552E7FA8) : const Color(0x33102A45),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: fromUser ? const Color(0x5548D6F5) : const Color(0x2248D6F5),
          ),
        ),
        child: SelectableText(
          message.text,
          style: const TextStyle(
            color: Color(0xFFEAF9FF),
            fontSize: 12.5,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ok ? const Color(0xFF52E5A0) : const Color(0xFFF0A34B),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(color: Color(0x99CFEFFF), fontSize: 11),
          ),
        ],
      ),
    );
  }
}
