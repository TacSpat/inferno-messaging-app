import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/all_themes.dart';
import 'unified_picker.dart';

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
  bool _showPicker = false;

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
    setState(() { _hasText = false; _showPicker = false; });
    _focusNode.requestFocus();
  }

  void _insertEmoji(String emoji) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.isValid ? selection.start : text.length;
    final newText = text.substring(0, start) + emoji + text.substring(start);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
    setState(() => _hasText = newText.trim().isNotEmpty);
    _focusNode.requestFocus();
  }

  void _sendGifOrSticker(String url) {
    widget.onSend(url);
    setState(() => _showPicker = false);
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Picker panel (above input, matching Rails: absolute bottom-12 right-0)
        if (_showPicker)
          Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16, bottom: 4),
              child: UnifiedPicker(
                onEmojiSelect: _insertEmoji,
                onGifSelect: _sendGifOrSticker,
                onStickerSelect: _sendGifOrSticker,
              ),
            ),
          ),
        // Input bar
        Padding(
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
                    onPressed: () {
                      // TODO: file picker
                    },
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
                // Emoji/Picker toggle
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: IconButton(
                    icon: Icon(
                      _showPicker ? Icons.keyboard : Icons.emoji_emotions_outlined,
                      color: _showPicker ? c.accent : c.gray400,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _showPicker = !_showPicker),
                    tooltip: _showPicker ? 'Keyboard' : 'Emoji, GIFs & Stickers',
                    splashRadius: 18,
                  ),
                ),
                // Send button
                Padding(
                  padding: const EdgeInsets.all(4),
                  child: IconButton(
                    icon: Icon(Icons.send, color: _hasText ? c.accent : c.gray500, size: 20),
                    onPressed: _hasText ? _send : null,
                    tooltip: 'Send',
                    splashRadius: 18,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
