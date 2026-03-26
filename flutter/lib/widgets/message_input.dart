import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../theme/all_themes.dart';
import '../theme/ui_effects.dart';
import '../theme/theme_provider.dart';
import 'unified_picker.dart';

class MessageInput extends ConsumerStatefulWidget {
  final void Function(String content) onSend;
  /// Called when user wants to send files — returns list of local File paths
  final Future<List<String>> Function(List<File> files)? onUploadFiles;
  final String? channelName;
  final String? recipientName;
  final VoidCallback? onTyping;
  /// When set, pre-fills the input with this content for editing
  final String? editContent;
  /// Called when user presses Escape during edit mode
  final VoidCallback? onEditCancel;

  const MessageInput({
    super.key,
    required this.onSend,
    this.onUploadFiles,
    this.channelName,
    this.recipientName,
    this.onTyping,
    this.editContent,
    this.onEditCancel,
  });

  @override
  ConsumerState<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends ConsumerState<MessageInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _showPicker = false;
  bool _uploading = false;
  bool _dragging = false;
  double _fireFuel = 0.0;
  final List<File> _pendingFiles = [];

  @override
  void didUpdateWidget(MessageInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When entering edit mode, pre-fill the input
    if (widget.editContent != null && widget.editContent != oldWidget.editContent) {
      _controller.text = widget.editContent!;
      _controller.selection = TextSelection.collapsed(offset: widget.editContent!.length);
      setState(() => _hasText = true);
      _focusNode.requestFocus();
    }
    // When leaving edit mode, clear the input
    if (widget.editContent == null && oldWidget.editContent != null) {
      _controller.clear();
      setState(() => _hasText = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() async {
    final text = _controller.text.trim();

    // If there are pending files, upload them first
    if (_pendingFiles.isNotEmpty) {
      await _uploadAndSend(text);
      return;
    }

    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    setState(() { _hasText = false; _showPicker = false; _fireFuel = 0.0; });
    _focusNode.requestFocus();
  }

  Future<void> _uploadAndSend(String text) async {
    if (widget.onUploadFiles == null) return;
    setState(() => _uploading = true);
    try {
      final urls = await widget.onUploadFiles!(_pendingFiles);
      final allContent = [
        if (text.isNotEmpty) text,
        ...urls,
      ].join('\n');
      if (allContent.isNotEmpty) {
        widget.onSend(allContent);
      }
      _controller.clear();
      setState(() {
        _pendingFiles.clear();
        _hasText = false;
        _showPicker = false;
      });
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
    _focusNode.requestFocus();
  }

  void _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null) {
      setState(() {
        for (final file in result.files) {
          if (file.path != null) {
            _pendingFiles.add(File(file.path!));
          }
        }
      });
    }
    _focusNode.requestFocus();
  }

  void _removeFile(int index) {
    setState(() => _pendingFiles.removeAt(index));
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

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() {
          _dragging = false;
          for (final xFile in details.files) {
            _pendingFiles.add(File(xFile.path));
          }
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag overlay indicator
          if (_dragging)
            Container(
              height: 60,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: c.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.accent, width: 2),
              ),
              child: Center(
                child: Text('Drop files here', style: TextStyle(color: c.accent, fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          // Picker panel (above input)
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
          // Pending files preview
          if (_pendingFiles.isNotEmpty)
            Container(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
              child: SizedBox(
                height: 80,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _pendingFiles.length,
                  itemBuilder: (context, index) {
                    final file = _pendingFiles[index];
                    final isImage = _isImage(file.path);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(
                        children: [
                          Container(
                            width: 80, height: 80,
                            decoration: BoxDecoration(
                              color: c.gray900,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: c.gray700),
                              image: isImage ? DecorationImage(image: FileImage(file), fit: BoxFit.cover) : null,
                            ),
                            child: !isImage
                                ? Center(child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.insert_drive_file, color: c.gray500, size: 24),
                                      const SizedBox(height: 2),
                                      Text(file.path.split('/').last.split('\\').last,
                                        style: TextStyle(color: c.gray500, fontSize: 9),
                                        maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                                    ],
                                  ))
                                : null,
                          ),
                          Positioned(
                            top: -4, right: -4,
                            child: GestureDetector(
                              onTap: () => _removeFile(index),
                              child: Container(
                                width: 20, height: 20,
                                decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
                                child: const Icon(Icons.close, size: 12, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          // Input bar with ember border + focus glow
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: _wrapWithEffects(c, AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              decoration: BoxDecoration(
                color: c.gray600,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focusNode.hasFocus ? c.accent.withValues(alpha: 0.5) : c.accent.withValues(alpha: 0.2),
                  width: 1,
                ),
                boxShadow: _focusNode.hasFocus ? [
                  BoxShadow(color: c.accent.withValues(alpha: 0.12), blurRadius: 20, spreadRadius: 0),
                  BoxShadow(color: c.accent.withValues(alpha: 0.04), blurRadius: 12, spreadRadius: 0),
                ] : null,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // File upload button
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: IconButton(
                      icon: Icon(Icons.add, color: c.gray400, size: 20),
                      onPressed: _uploading ? null : _pickFiles,
                      tooltip: 'Upload file',
                      splashRadius: 18,
                    ),
                  ),
                  // Text input
                  Expanded(
                    child: KeyboardListener(
                      focusNode: FocusNode(),
                      onKeyEvent: (event) {
                        if (event is! KeyDownEvent) return;
                        if (event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _send();
                        } else if (event.logicalKey == LogicalKeyboardKey.escape &&
                            widget.onEditCancel != null) {
                          widget.onEditCancel!();
                        }
                      },
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        onChanged: (v) {
                          setState(() {
                            _hasText = v.trim().isNotEmpty;
                            _fireFuel = (_fireFuel + 0.15).clamp(0.0, 1.0); // each key adds a bit
                          });
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
                  // Send button (shows upload progress when uploading)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: _uploading
                        ? const Padding(
                            padding: EdgeInsets.all(10),
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                          )
                        : IconButton(
                            icon: Icon(Icons.send,
                              color: (_hasText || _pendingFiles.isNotEmpty) ? c.accent : c.gray500,
                              size: 20),
                            onPressed: (_hasText || _pendingFiles.isNotEmpty) ? _send : null,
                            tooltip: 'Send',
                            splashRadius: 18,
                          ),
                  ),
                ],
              ),
            )),
          ),
        ],
      ),
    );
  }

  Widget _wrapWithEffects(InfernoColors c, Widget child) {
    final effects = ref.watch(uiEffectThemeProvider);

    if (effects.embers) {
      // Decay fuel each frame — BarFire's tick handles smoothing
      if (_fireFuel > 0) {
        Future.microtask(() {
          if (mounted) setState(() => _fireFuel = (_fireFuel - 0.012).clamp(0.0, 1.0));
        });
      }
      return BarFire(
        lit: _focusNode.hasFocus,
        color: c.accent,
        colorLight: Color.lerp(c.accent, Colors.orange, 0.35)!,
        flameCount: 36,
        maxFlameHeight: 22,
        fuel: _fireFuel,
        child: child,
      );
    }

    return child;
  }

  bool _isImage(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif'].contains(ext);
  }
}
