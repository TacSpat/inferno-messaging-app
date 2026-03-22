import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/all_themes.dart';

class MessageInput extends StatefulWidget {
  final void Function(String content) onSend;
  final String? channelName;
  final String? recipientName;
  final VoidCallback? onTyping;

  const MessageInput({super.key, required this.onSend, this.channelName, this.recipientName, this.onTyping});

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    setState(() => _hasText = false);
    _focusNode.requestFocus();
  }

  String get _placeholder {
    if (widget.channelName != null) return 'Message #${widget.channelName}';
    if (widget.recipientName != null) return 'Message @${widget.recipientName}';
    return 'Send a message...';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Container(
        decoration: BoxDecoration(
          color: c.gray600,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // File upload button
            Padding(
              padding: const EdgeInsets.all(4),
              child: IconButton(
                icon: Icon(Icons.add, color: c.gray400, size: 20),
                onPressed: () {},
                tooltip: 'Upload file',
                splashRadius: 18,
              ),
            ),
            // Text input
            Expanded(
              child: KeyboardListener(
                focusNode: FocusNode(),
                onKeyEvent: (event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    _send();
                  }
                },
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  onChanged: (v) {
                    setState(() => _hasText = v.trim().isNotEmpty);
                    if (v.trim().isNotEmpty) widget.onTyping?.call();
                  },
                  maxLines: 6,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: _placeholder,
                    hintStyle: TextStyle(color: c.gray500),
                    border: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  style: TextStyle(color: c.gray200, fontSize: 14, height: 1.5),
                ),
              ),
            ),
            // Emoji button
            Padding(
              padding: const EdgeInsets.all(4),
              child: IconButton(
                icon: Icon(Icons.emoji_emotions_outlined, color: c.gray400, size: 20),
                onPressed: () {},
                tooltip: 'Emoji',
                splashRadius: 18,
              ),
            ),
            // Send button
            Padding(
              padding: const EdgeInsets.all(4),
              child: IconButton(
                icon: Icon(
                  Icons.send,
                  color: _hasText ? c.accent : c.gray500,
                  size: 20,
                ),
                onPressed: _hasText ? _send : null,
                tooltip: 'Send',
                splashRadius: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
