import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../database/database.dart';
import '../models/permission.dart';
import '../providers/database_provider.dart';
import '../providers/server_settings_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/all_themes.dart';
import '../theme/ui_effects.dart';
import '../theme/theme_provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'unified_picker.dart';

/// Pattern to match custom emoji in text: :name:
final _emojiColonPattern = RegExp(r':([a-zA-Z0-9_]+):');

/// TextEditingController that renders :emoji_name: as inline images
class _EmojiRichController extends TextEditingController {
  Map<String, String> emojiMap = {}; // name -> url

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (emojiMap.isEmpty) {
      return TextSpan(text: text, style: style);
    }

    final children = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in _emojiColonPattern.allMatches(text)) {
      final name = match.group(1)!;
      final url = emojiMap[name];
      if (url == null) continue;

      // Add text before this emoji
      if (match.start > lastEnd) {
        children.add(TextSpan(text: text.substring(lastEnd, match.start), style: style));
      }

      // Add inline emoji image
      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: CachedNetworkImage(
            imageUrl: url,
            width: 22, height: 22,
            fit: BoxFit.contain,
            errorWidget: (_, __, ___) => Text(match.group(0)!, style: style),
          ),
        ),
      ));

      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < text.length) {
      children.add(TextSpan(text: text.substring(lastEnd), style: style));
    }

    if (children.isEmpty) {
      return TextSpan(text: text, style: style);
    }

    return TextSpan(children: children, style: style);
  }
}

class MessageInput extends ConsumerStatefulWidget {
  final Future<void> Function(String content) onSend;
  /// Rich send with metadata: spoiler flag, file URLs
  final Future<void> Function(String content, {bool spoiler, List<String>? fileUrls})? onSendWithMeta;
  /// Called when user wants to send files — returns list of Blossom URLs
  final Future<List<String>> Function(List<File> files)? onUploadFiles;
  final String? channelName;
  final String? recipientName;
  final VoidCallback? onTyping;
  /// When set, pre-fills the input with this content for editing
  final String? editContent;
  /// Called when user presses Escape during edit mode
  final VoidCallback? onEditCancel;
  /// Custom emoji map: name -> url (for inline rendering in input)
  final Map<String, String> customEmojis;
  /// Server ID for @mention autocomplete (null for DMs)
  final int? serverId;
  /// Whether this input is currently the active/visible one (for IndexedStack).
  /// When false, drop targets are disabled to prevent duplicate file drops.
  final bool isActive;
  /// Compact mode hides the spoiler toggle and tightens padding. Used in
  /// narrow contexts like the voice sidechat panel.
  final bool compact;

  const MessageInput({
    super.key,
    required this.onSend,
    this.onSendWithMeta,
    this.onUploadFiles,
    this.channelName,
    this.recipientName,
    this.onTyping,
    this.editContent,
    this.onEditCancel,
    this.customEmojis = const {},
    this.serverId,
    this.isActive = true,
    this.compact = false,
  });

  @override
  ConsumerState<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends ConsumerState<MessageInput> {
  final _controller = _EmojiRichController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _showPicker = false;
  OverlayEntry? _pickerOverlay;
  final GlobalKey _emojiButtonKey = GlobalKey();
  final LayerLink _pickerLayerLink = LayerLink();
  bool _uploading = false;
  bool _sending = false;
  bool _dragging = false;
  bool _isSpoiler = false;
  double _fireFuel = 0.0;
  final List<File> _pendingFiles = [];
  final Set<int> _spoilerFileIndices = {};

  // Mention autocomplete state
  OverlayEntry? _mentionOverlay;
  final LayerLink _mentionLayerLink = LayerLink();
  List<_MentionCandidate> _mentionResults = [];
  int _mentionSelectionIndex = 0;
  int _mentionQueryStart = -1; // cursor position of the '@'
  List<RemoteMember> _cachedMembers = [];
  List<Role> _cachedRoles = [];
  bool _membersLoaded = false;
  bool _canSend = true; // default true, checked async
  bool _canAttachFiles = true;
  bool _canSendGifs = true;
  bool _canSendCustomEmojis = true;
  bool _canSendCustomStickers = true;
  bool _canMentionEveryone = true;

  @override
  void dispose() {
    _hidePicker();
    _hideMentionOverlay();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MessageInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.customEmojis != oldWidget.customEmojis) {
      _controller.emojiMap = widget.customEmojis;
    }
    if (widget.channelName != oldWidget.channelName || widget.recipientName != oldWidget.recipientName) {
      // Channel/conversation changed — clear pending files and spoiler state
      setState(() {
        _pendingFiles.clear();
        _spoilerFileIndices.clear();
        _isSpoiler = false;
        _controller.clear();
        _hasText = false;
      });
    }
    if (widget.serverId != oldWidget.serverId) {
      _membersLoaded = false;
      _cachedMembers = [];
      _cachedRoles = [];
      _hideMentionOverlay();
      _checkSendPermission();
    }
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
    _controller.emojiMap = widget.customEmojis;
    _focusNode.addListener(() { if (mounted) setState(() {}); });
    _checkSendPermission();
  }

  Future<void> _checkSendPermission() async {
    if (widget.serverId == null) return; // DMs — always allowed
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final permSvc = ref.read(permissionServiceProvider);
    final sid = widget.serverId!;
    final pk = auth.publicKeyHex!;
    final results = await Future.wait([
      permSvc.hasPermission(sid, pk, Permission.sendMessages),
      permSvc.hasPermission(sid, pk, Permission.attachFiles),
      permSvc.hasPermission(sid, pk, Permission.sendGifs),
      permSvc.hasPermission(sid, pk, Permission.sendCustomEmojis),
      permSvc.hasPermission(sid, pk, Permission.sendCustomStickers),
      permSvc.hasPermission(sid, pk, Permission.mentionEveryone),
    ]);
    if (mounted) {
      setState(() {
        _canSend = results[0];
        _canAttachFiles = results[1];
        _canSendGifs = results[2];
        _canSendCustomEmojis = results[3];
        _canSendCustomStickers = results[4];
        _canMentionEveryone = results[5];
      });
    }
  }

  static final _nsecPattern = RegExp(r'nsec1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58,}', caseSensitive: false);

  void _send() async {
    if (_sending || _uploading) return;
    final text = _controller.text.trim();

    // If there are pending files, upload them first
    if (_pendingFiles.isNotEmpty) {
      await _uploadAndSend(text);
      return;
    }

    if (text.isEmpty) return;

    // Block messages containing private keys (nsec) per Nostr design guidelines
    if (_nsecPattern.hasMatch(text)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Your message contains a private key (nsec). '
              'Posting this would permanently compromise your account. Message blocked.'),
          backgroundColor: Color(0xFFD32F2F),
          duration: Duration(seconds: 5),
        ));
      }
      return;
    }
    final spoiler = _isSpoiler;
    // Clear input immediately for snappy UX, but block re-sends until complete
    _controller.clear();
    _hidePicker();
    _hideMentionOverlay();
    setState(() { _sending = true; _hasText = false; _showPicker = false; _fireFuel = 0.0; _isSpoiler = false; });
    _focusNode.requestFocus();
    try {
      if (widget.onSendWithMeta != null && spoiler) {
        await widget.onSendWithMeta!(text, spoiler: spoiler);
      } else {
        await widget.onSend(text);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _togglePicker() {
    if (_showPicker) {
      _hidePicker();
    } else {
      _showPickerOverlay();
    }
    setState(() => _showPicker = !_showPicker);
  }

  void _showPickerOverlay() {
    _pickerOverlay?.remove();
    final inputBox = context.findRenderObject() as RenderBox?;
    if (inputBox == null) return;
    final pickerWidth = (inputBox.size.width * 0.55).clamp(300.0, 450.0);

    _pickerOverlay = OverlayEntry(builder: (ctx) => Stack(children: [
      Positioned.fill(child: GestureDetector(
        onTap: () { _hidePicker(); setState(() => _showPicker = false); },
        behavior: HitTestBehavior.translucent,
        child: Container(color: Colors.transparent),
      )),
      CompositedTransformFollower(
        link: _pickerLayerLink,
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.bottomRight,
        offset: const Offset(0, -4),
        child: SizedBox(
          width: pickerWidth,
          height: 380,
          child: Material(
            color: Colors.transparent,
            child: UnifiedPicker(
              onEmojiSelect: (emoji) { _insertEmoji(emoji); },
              onGifSelect: _canSendGifs ? (url) { _hidePicker(); setState(() => _showPicker = false); _sendGifOrSticker(url); } : null,
              onStickerSelect: _canSendCustomStickers ? (url) { _hidePicker(); setState(() => _showPicker = false); _sendGifOrSticker(url); } : null,
              customEmojis: widget.customEmojis,
              canSendGifs: _canSendGifs,
              canSendCustomEmojis: _canSendCustomEmojis,
              canSendCustomStickers: _canSendCustomStickers,
            ),
          ),
        ),
      ),
    ]));
    Overlay.of(context).insert(_pickerOverlay!);
  }

  void _hidePicker() {
    _pickerOverlay?.remove();
    _pickerOverlay = null;
  }

  Future<void> _uploadAndSend(String text) async {
    if (widget.onUploadFiles == null) return;
    setState(() => _uploading = true);
    try {
      final urls = await widget.onUploadFiles!(List.of(_pendingFiles));
      // Prefix spoilered file URLs with "spoiler:" so the renderer can detect them
      final taggedUrls = <String>[];
      for (int i = 0; i < urls.length; i++) {
        taggedUrls.add(_spoilerFileIndices.contains(i) ? 'spoiler:${urls[i]}' : urls[i]);
      }
      if (widget.onSendWithMeta != null) {
        // Structured send: file URLs separate from content, with spoiler flag
        final content = [
          if (text.isNotEmpty) text,
          ...taggedUrls,
        ].join('\n');
        if (content.isNotEmpty || taggedUrls.isNotEmpty) {
          widget.onSendWithMeta!(content, spoiler: _isSpoiler, fileUrls: taggedUrls);
        }
      } else {
        // Legacy: concatenate URLs into content
        final allContent = [
          if (text.isNotEmpty) text,
          ...taggedUrls,
        ].join('\n');
        if (allContent.isNotEmpty) {
          widget.onSend(allContent);
        }
      }
      _controller.clear();
      _hidePicker();
      setState(() {
        _pendingFiles.clear();
        _spoilerFileIndices.clear();
        _hasText = false;
        _showPicker = false;
        _isSpoiler = false;
      });
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
    _focusNode.requestFocus();
  }

  void _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result != null) {
      final files = result.files.where((f) => f.path != null).map((f) => File(f.path!));
      setState(() {
        final rejected = _addValidatedFiles(files);
        _showRejectionSnackbar(rejected);
      });
    }
    _focusNode.requestFocus();
  }

  void _removeFile(int index) {
    setState(() {
      _pendingFiles.removeAt(index);
      // Rebuild spoiler indices: remove this index, shift higher ones down
      final updated = <int>{};
      for (final i in _spoilerFileIndices) {
        if (i < index) updated.add(i);
        if (i > index) updated.add(i - 1);
      }
      _spoilerFileIndices
        ..clear()
        ..addAll(updated);
    });
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

  // --- Mention autocomplete ---

  Future<void> _loadMembers() async {
    if (_membersLoaded || widget.serverId == null) return;
    final db = ref.read(databaseProvider);
    _cachedMembers = await (db.select(db.remoteMembers)
          ..where((m) => m.serverId.equals(widget.serverId!)))
        .get();
    _cachedRoles = await (db.select(db.roles)
          ..where((r) => r.serverId.equals(widget.serverId!)))
        .get();
    _membersLoaded = true;
  }

  void _checkMention(String text) {
    if (widget.serverId == null) {
      _hideMentionOverlay();
      return;
    }

    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _hideMentionOverlay();
      return;
    }

    final cursor = selection.baseOffset;
    final beforeCursor = text.substring(0, cursor);

    // Find @ preceded by whitespace or start-of-string
    final match = RegExp(r'(?:^|\s)@(\w{0,20})$').firstMatch(beforeCursor);
    if (match == null) {
      _hideMentionOverlay();
      return;
    }

    final query = match.group(1)!.toLowerCase();
    _mentionQueryStart = match.start + (beforeCursor[match.start] == '@' ? 0 : 1); // skip whitespace

    _loadMembers().then((_) {
      if (!mounted) return;
      final candidates = <_MentionCandidate>[];

      // Special mentions (gated by mentionEveryone permission)
      if (_canMentionEveryone) {
        if ('everyone'.startsWith(query)) {
          candidates.add(_MentionCandidate(name: 'everyone', displayName: '@everyone', isSpecial: true));
        }
        if ('here'.startsWith(query)) {
          candidates.add(_MentionCandidate(name: 'here', displayName: '@here', isSpecial: true));
        }
      }

      // Filter members
      for (final m in _cachedMembers) {
        final username = m.username?.toLowerCase() ?? '';
        final display = m.displayName?.toLowerCase() ?? '';
        if (username.startsWith(query) || display.startsWith(query) || (query.isEmpty)) {
          candidates.add(_MentionCandidate(
            name: m.username ?? m.pubkey.substring(0, 12),
            displayName: m.displayName ?? m.username ?? m.pubkey.substring(0, 12),
            pubkey: m.pubkey,
            avatarUrl: m.avatarUrl,
          ));
        }
        if (candidates.length >= 12) break;
      }

      // Filter mentionable roles (all except owner)
      for (final role in _cachedRoles) {
        if (role.name == null) continue;
        // Skip system roles (owner, voice provider, @everyone)
        final rn = role.name!.toLowerCase();
        if (rn == 'owner' || rn == '@everyone' || rn == 'everyone') continue;
        if (role.roleType == 'voice_provider' || rn == 'voice provider') continue;
        if (role.permissions != null) {
          try {
            final perms = json.decode(role.permissions!) as Map<String, dynamic>;
            if (perms['owner'] == true) continue;
          } catch (_) {}
        }
        if (candidates.length >= 12) break;
        final roleName = role.name!.toLowerCase();
        if (roleName.startsWith(query) || query.isEmpty) {
          Color? color;
          if (role.color != null && role.color!.isNotEmpty) {
            final hex = role.color!.replaceFirst('#', '');
            if (hex.length == 6) color = Color(int.parse('FF$hex', radix: 16));
          }
          candidates.add(_MentionCandidate(
            name: role.name!,
            displayName: '@${role.name}',
            isRole: true,
            roleColor: color,
          ));
        }
      }

      if (candidates.isEmpty) {
        _hideMentionOverlay();
        return;
      }

      setState(() {
        _mentionResults = candidates;
        _mentionSelectionIndex = 0;
      });
      _showMentionOverlay();
    });
  }

  void _showMentionOverlay() {
    _mentionOverlay?.remove();
    final c = ref.read(infernoColorsProvider);

    _mentionOverlay = OverlayEntry(builder: (ctx) {
      return Stack(children: [
        Positioned.fill(child: GestureDetector(
          onTap: _hideMentionOverlay,
          behavior: HitTestBehavior.translucent,
          child: Container(color: Colors.transparent),
        )),
        CompositedTransformFollower(
          link: _mentionLayerLink,
          targetAnchor: Alignment.topLeft,
          followerAnchor: Alignment.bottomLeft,
          offset: const Offset(0, -4),
          child: Material(
            color: Colors.transparent,
            child: _MentionList(
              candidates: _mentionResults,
              selectedIndex: _mentionSelectionIndex,
              colors: c,
              onSelect: _selectMention,
            ),
          ),
        ),
      ]);
    });
    Overlay.of(context).insert(_mentionOverlay!);
  }

  void _hideMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    if (_mentionResults.isNotEmpty) {
      setState(() => _mentionResults = []);
    }
  }

  void _selectMention(_MentionCandidate candidate) {
    final text = _controller.text;
    final cursor = _controller.selection.baseOffset;
    final before = text.substring(0, _mentionQueryStart);
    final after = text.substring(cursor);
    final mention = '@${candidate.name} ';
    final newText = '$before$mention$after';
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: before.length + mention.length),
    );
    setState(() => _hasText = newText.trim().isNotEmpty);
    _hideMentionOverlay();
    _focusNode.requestFocus();
  }

  bool _handleMentionKey(KeyEvent event) {
    if (_mentionOverlay == null || _mentionResults.isEmpty) return false;
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _mentionSelectionIndex = (_mentionSelectionIndex - 1).clamp(0, _mentionResults.length - 1);
      });
      _showMentionOverlay(); // rebuild overlay
      return true;
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _mentionSelectionIndex = (_mentionSelectionIndex + 1).clamp(0, _mentionResults.length - 1);
      });
      _showMentionOverlay();
      return true;
    } else if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.tab) {
      _selectMention(_mentionResults[_mentionSelectionIndex]);
      return true;
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      _hideMentionOverlay();
      return true;
    }
    return false;
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
    final c = ref.watch(infernoColorsProvider);

    return DropTarget(
      enable: widget.isActive,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        final files = details.files.map((xFile) => File(xFile.path));
        setState(() {
          _dragging = false;
          final rejected = _addValidatedFiles(files);
          _showRejectionSnackbar(rejected);
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
          // Spoiler badge
          if (_isSpoiler && (_pendingFiles.isNotEmpty || _hasText))
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: c.accent.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                border: Border.all(color: c.accent.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.visibility_off, size: 14, color: c.accent),
                  const SizedBox(width: 6),
                  Text('SPOILER', style: TextStyle(color: c.accent, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                ],
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
                    final fileName = file.path.split('/').last.split('\\').last;
                    final isSpoilered = _spoilerFileIndices.contains(index);
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 80, height: 80,
                            decoration: BoxDecoration(
                              color: c.gray900,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: isSpoilered ? c.accent : c.gray700),
                              image: isImage && !isSpoilered ? DecorationImage(image: FileImage(file), fit: BoxFit.cover) : null,
                            ),
                            child: isImage && isSpoilered
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(7),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        ImageFiltered(
                                          imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                                          child: Image.file(file, fit: BoxFit.cover),
                                        ),
                                        Center(child: Text('SPOILER', style: TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold))),
                                      ],
                                    ),
                                  )
                                : !isImage
                                    ? Center(child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Icon(_fileIcon(file.path), color: c.gray500, size: 24),
                                          const SizedBox(height: 2),
                                          Text(fileName,
                                            style: TextStyle(color: c.gray500, fontSize: 9),
                                            maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                                        ],
                                      ))
                                    : null,
                          ),
                          // Close button
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
                          // Spoiler toggle (eye icon, bottom-left)
                          Positioned(
                            bottom: -2, left: -2,
                            child: GestureDetector(
                              onTap: () => setState(() {
                                if (isSpoilered) {
                                  _spoilerFileIndices.remove(index);
                                } else {
                                  _spoilerFileIndices.add(index);
                                }
                              }),
                              child: Tooltip(
                                message: isSpoilered ? 'Remove spoiler' : 'Mark as spoiler',
                                child: Container(
                                  width: 20, height: 20,
                                  decoration: BoxDecoration(
                                    color: isSpoilered ? c.accent : c.gray800,
                                    shape: BoxShape.circle,
                                    border: Border.all(color: isSpoilered ? c.accent : c.gray600, width: 1),
                                  ),
                                  child: Icon(
                                    isSpoilered ? Icons.visibility_off : Icons.visibility_off_outlined,
                                    size: 11,
                                    color: isSpoilered ? Colors.white : c.gray400,
                                  ),
                                ),
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
          CompositedTransformTarget(
            link: _mentionLayerLink,
            child: Padding(
            padding: widget.compact
                ? const EdgeInsets.fromLTRB(8, 4, 8, 4)
                : const EdgeInsets.fromLTRB(16, 8, 16, 6),
            child: _wrapWithEffects(c, AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              decoration: BoxDecoration(
                color: c.gray600,
                borderRadius: BorderRadius.circular(22),
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
                      onPressed: (_uploading || !_canAttachFiles) ? null : _pickFiles,
                      tooltip: 'Upload file',
                      splashRadius: 18,
                    ),
                  ),
                  // Text input
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, event) {
                        // Let mention autocomplete handle keys first
                        if (_handleMentionKey(event)) return KeyEventResult.handled;
                        if (event is! KeyDownEvent) return KeyEventResult.ignored;
                        if (event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          _send();
                          return KeyEventResult.handled;
                        } else if (event.logicalKey == LogicalKeyboardKey.escape &&
                            widget.onEditCancel != null) {
                          widget.onEditCancel!();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        enabled: _canSend,
                        onChanged: (v) {
                          setState(() {
                            _hasText = v.trim().isNotEmpty;
                            _fireFuel = (_fireFuel + 0.15).clamp(0.0, 1.0); // each key adds a bit
                          });
                          if (v.trim().isNotEmpty) widget.onTyping?.call();
                          _checkMention(v);
                        },
                        maxLines: 6,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          hintText: _canSend ? _placeholder : 'You do not have permission to send messages',
                          hintStyle: TextStyle(color: c.gray500),
                          border: InputBorder.none,
                          filled: false,
                          contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        ),
                        style: TextStyle(color: c.gray200, fontSize: 14, height: 1.5),
                      ),
                    ),
                  ),
                  // Spoiler toggle (hidden in compact / sidechat mode)
                  if (!widget.compact)
                    Padding(
                      padding: const EdgeInsets.all(4),
                      child: IconButton(
                        icon: Icon(
                          _isSpoiler ? Icons.visibility_off : Icons.visibility_off_outlined,
                          color: _isSpoiler ? c.accent : c.gray400,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _isSpoiler = !_isSpoiler),
                        tooltip: _isSpoiler ? 'Remove spoiler' : 'Mark as spoiler',
                        splashRadius: 18,
                      ),
                    ),
                  // Emoji/Picker toggle
                  CompositedTransformTarget(
                    link: _pickerLayerLink,
                    child: Padding(
                      key: _emojiButtonKey,
                      padding: const EdgeInsets.all(4),
                      child: IconButton(
                        icon: Icon(
                          _showPicker ? Icons.keyboard : Icons.emoji_emotions_outlined,
                          color: _showPicker ? c.accent : c.gray400,
                          size: 20,
                        ),
                        onPressed: _togglePicker,
                        tooltip: _showPicker ? 'Keyboard' : 'Emoji, GIFs & Stickers',
                        splashRadius: 18,
                      ),
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
          ),
        ],
      ),
    );
  }

  Widget _wrapWithEffects(InfernoColors c, Widget child) {
    final effects = ref.watch(uiEffectThemeProvider);

    if (effects.embers) {
      // Decay fuel each frame
      if (_fireFuel > 0) {
        Future.microtask(() {
          if (mounted) setState(() => _fireFuel = (_fireFuel - 0.012).clamp(0.0, 1.0));
        });
      }

      // Electric theme uses lightning arcs — capped lower than fire
      if (effects.name == 'electric') {
        return BarElectric(
          lit: _focusNode.hasFocus,
          color: c.accent,
          colorLight: Color.lerp(c.accent, Colors.white, 0.6)!,
          fuel: (_fireFuel * 0.4).clamp(0.0, 0.4),
          child: child,
        );
      }

      // Inferno/subtle use fire
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
    return ['png', 'jpg', 'jpeg', 'gif', 'webp', 'avif', 'apng', 'svg'].contains(ext);
  }

  bool _isVideo(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['mp4', 'webm', 'mov'].contains(ext);
  }

  bool _isAudio(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['mp3', 'ogg', 'wav', 'webm', 'm4a'].contains(ext);
  }

  static const _allowedExtensions = {
    'jpeg', 'jpg', 'png', 'gif', 'webp', 'apng', 'svg', 'avif', // images
    'mp4', 'webm', 'mov', // video
    'mp3', 'ogg', 'wav', 'm4a', // audio
    'pdf', 'txt', // documents
  };

  /// Returns list of rejected filenames, adds valid files to _pendingFiles
  List<String> _addValidatedFiles(Iterable<File> files) {
    final rejected = <String>[];
    for (final file in files) {
      final ext = file.path.split('.').last.toLowerCase();
      if (_allowedExtensions.contains(ext)) {
        _pendingFiles.add(file);
      } else {
        rejected.add(file.path.split('/').last.split('\\').last);
      }
    }
    return rejected;
  }

  void _showRejectionSnackbar(List<String> rejected) {
    if (rejected.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Unsupported file type: ${rejected.join(', ')}'),
      duration: const Duration(seconds: 3),
    ));
  }

  IconData _fileIcon(String path) {
    if (_isImage(path)) return Icons.image;
    if (_isVideo(path)) return Icons.videocam;
    if (_isAudio(path)) return Icons.audiotrack;
    final ext = path.split('.').last.toLowerCase();
    if (ext == 'pdf') return Icons.picture_as_pdf;
    return Icons.insert_drive_file;
  }
}

class _MentionCandidate {
  final String name;
  final String displayName;
  final String? pubkey;
  final String? avatarUrl;
  final bool isSpecial;
  final bool isRole;
  final Color? roleColor;
  const _MentionCandidate({
    required this.name,
    required this.displayName,
    this.pubkey,
    this.avatarUrl,
    this.isSpecial = false,
    this.isRole = false,
    this.roleColor,
  });
}

class _MentionList extends StatelessWidget {
  final List<_MentionCandidate> candidates;
  final int selectedIndex;
  final InfernoColors colors;
  final void Function(_MentionCandidate) onSelect;

  const _MentionList({
    required this.candidates,
    required this.selectedIndex,
    required this.colors,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        color: colors.gray800,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.gray700),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, -4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 4),
          shrinkWrap: true,
          itemCount: candidates.length,
          itemBuilder: (context, index) {
            final c = candidates[index];
            final selected = index == selectedIndex;
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => onSelect(c),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  color: selected ? colors.accent.withValues(alpha: 0.15) : Colors.transparent,
                  child: Row(
                    children: [
                      if (c.isSpecial)
                        Container(
                          width: 24, height: 24,
                          decoration: BoxDecoration(
                            color: colors.accentDark.withValues(alpha: 0.3),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.alternate_email, size: 14, color: colors.accent),
                        )
                      else if (c.isRole)
                        Container(
                          width: 24, height: 24,
                          decoration: BoxDecoration(
                            color: (c.roleColor ?? colors.accent).withValues(alpha: 0.25),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.shield, size: 14, color: c.roleColor ?? colors.accent),
                        )
                      else
                        CircleAvatar(
                          radius: 12,
                          backgroundColor: colors.gray700,
                          child: Text(
                            c.displayName[0].toUpperCase(),
                            style: TextStyle(color: colors.gray200, fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(c.displayName, style: TextStyle(
                              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500,
                            ), overflow: TextOverflow.ellipsis),
                            if (c.isRole)
                              Text('Role', style: TextStyle(
                                color: colors.gray500, fontSize: 11,
                              ), overflow: TextOverflow.ellipsis)
                            else if (!c.isSpecial && c.name != c.displayName)
                              Text('@${c.name}', style: TextStyle(
                                color: colors.gray500, fontSize: 11,
                              ), overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
