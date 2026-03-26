import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/servers_provider.dart';
import '../providers/realtime_provider.dart';
import '../providers/server_settings_provider.dart';
import '../theme/all_themes.dart';
import 'reaction_bar.dart';
import 'message_content.dart';
import 'user_profile_card.dart';
import '../screens/main_shell.dart';

typedef MessageReplyCallback = void Function(Message message, String authorName, String preview);

typedef MessageEditCallback = void Function(Message message);

class MessageList extends ConsumerStatefulWidget {
  final int? channelId;
  final int? conversationId;
  final MessageReplyCallback? onReply;
  final MessageEditCallback? onEdit;
  final Channel? channel;
  const MessageList({super.key, this.channelId, this.conversationId, this.onReply, this.onEdit, this.channel});

  /// Active instance registry — allows external code to scroll to a message
  static _MessageListState? _activeInstance;

  /// Scroll the active message list to a specific message and highlight it
  static void scrollToMessage(String nostrEventId) {
    _activeInstance?._scrollToAndHighlight(nostrEventId);
  }

  @override
  ConsumerState<MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<MessageList> {
  ScrollController? _scrollController;
  // Cache resolved author info: pubkey -> {name, avatarUrl}
  final Map<String, _AuthorInfo> _authorCache = {};
  // Cached reference to MainShellState — saved early so it's safe to use in dispose()
  MainShellState? _mainShell;
  // Cached message stream — prevents recreation on parent rebuilds which causes image flicker
  Stream<List<Message>>? _messageStream;
  int? _streamChannelId;
  // Message highlight state — when scrolling to a pinned message
  String? _highlightedEventId;

  @override
  void initState() {
    super.initState();
    _initScrollController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mainShell = context.findAncestorStateOfType<MainShellState>();
  }

  @override
  void didUpdateWidget(MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId || oldWidget.conversationId != widget.conversationId) {
      // Save current scroll offset for the old channel/conversation
      _saveScrollOffset(oldWidget.channelId ?? oldWidget.conversationId ?? 0);
      // Create new controller for the new channel
      _scrollController?.dispose();
      _initScrollController();
      _authorCache.clear();
    }
  }

  void _initScrollController() {
    final savedOffset = _mainShell?.getScrollOffset((widget.channelId ?? widget.conversationId ?? 0).toString());
    _scrollController = ScrollController(initialScrollOffset: savedOffset ?? 0.0);
  }

  void _saveScrollOffset(int channelId) {
    if (_scrollController != null && _scrollController!.hasClients) {
      _mainShell?.saveScrollOffset(channelId.toString(), _scrollController!.offset);
    }
  }

  @override
  void dispose() {
    if (MessageList._activeInstance == this) MessageList._activeInstance = null;
    _saveScrollOffset(widget.channelId ?? widget.conversationId ?? 0);
    _scrollController?.dispose();
    super.dispose();
  }

  // Cache latest messages for scroll-to lookup
  List<Message> _lastMessages = [];

  /// Scroll to a message by nostrEventId and highlight it briefly
  Future<void> _scrollToAndHighlight(String nostrEventId) async {
    if (_scrollController == null || !_scrollController!.hasClients) return;

    final index = _lastMessages.indexWhere((m) => m.nostrEventId == nostrEventId);
    if (index == -1) return;

    setState(() => _highlightedEventId = nostrEventId);

    final maxScroll = _scrollController!.position.maxScrollExtent;
    final totalMessages = _lastMessages.length;
    if (totalMessages == 0) return;

    // Phase 1: Quick jump to approximate area (gets message into the build tree)
    final fraction = index / totalMessages;
    final approxOffset = (fraction * maxScroll).clamp(0.0, maxScroll);
    _scrollController!.jumpTo(approxOffset);

    // Wait for the frame to build so the GlobalObjectKey is available
    await _waitForBuild();

    // Phase 2: Precise smooth scroll to center the actual message widget
    for (int attempt = 0; attempt < 3; attempt++) {
      if (!mounted) return;
      final ctx = GlobalObjectKey('msg-$nostrEventId').currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOutCubic,
          alignment: 0.5, // center of viewport
        );
        return _scheduleHighlightClear();
      }
      // Not found yet — nudge the scroll and retry
      final nudge = (attempt + 1) * 200.0;
      final nudged = (approxOffset + nudge).clamp(0.0, maxScroll);
      _scrollController!.jumpTo(nudged);
      await _waitForBuild();
    }

    _scheduleHighlightClear();
  }

  Future<void> _waitForBuild() async {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => completer.complete());
    await completer.future;
  }

  void _scheduleHighlightClear() {
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _highlightedEventId = null);
    });
  }

  Future<_AuthorInfo> _resolveAuthor(String pubkey) async {
    // Cache name+avatar but always resolve role color fresh (roles can change after sync)
    String name;
    String? avatarUrl;

    final cached = _authorCache[pubkey];
    if (cached != null) {
      name = cached.name;
      avatarUrl = cached.avatarUrl;
    } else {
      final db = ref.read(databaseProvider);
      name = '${pubkey.substring(0, 8)}...';

      final contact = await db.contactsDao.getByPubkey(pubkey);
      if (contact != null) {
        name = contact.displayName ?? contact.username ?? name;
        avatarUrl = contact.avatarUrl;
      } else {
        final members = await (db.select(db.remoteMembers)
              ..where((m) => m.pubkey.equals(pubkey))
              ..limit(1))
            .get();
        if (members.isNotEmpty) {
          final m = members.first;
          name = m.displayName ?? m.username ?? name;
          avatarUrl = m.avatarUrl;
        }
      }
      // Cache name+avatar only
      _authorCache[pubkey] = _AuthorInfo(name: name, avatarUrl: avatarUrl);
    }

    // Always resolve role color fresh
    Color? roleColor;
    final serverId = widget.channel?.serverId;
    if (serverId != null) {
      final permSvc = ref.read(permissionServiceProvider);
      final colorHex = await permSvc.getDisplayColor(serverId, pubkey);
      if (colorHex != '#ffffff') {
        roleColor = _parseHexColor(colorHex);
      }
    }

    return _AuthorInfo(name: name, avatarUrl: avatarUrl, roleColor: roleColor);
  }

  static Color? _parseHexColor(String hex) {
    try {
      final cleaned = hex.replaceFirst('#', '');
      if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {}
    return null;
  }

  Future<void> _handlePin(Message msg) async {
    if (widget.channel == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final svc = ref.read(groupMessageServiceProvider);
    await svc.togglePin(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      channel: widget.channel!,
      message: msg,
    );
  }

  Future<void> _handleDelete(Message msg) async {
    if (widget.channel == null || msg.nostrEventId == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final svc = ref.read(groupMessageServiceProvider);
    await svc.deleteMessage(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      channel: widget.channel!,
      eventId: msg.nostrEventId!,
    );
  }

  Future<void> _handleReaction(Message msg, String emoji) async {
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null || msg.nostrEventId == null) return;
    final svc = ref.read(reactionServiceProvider);
    await svc.toggleReaction(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      eventId: msg.nostrEventId!,
      emoji: emoji,
    );
  }

  @override
  Widget build(BuildContext context) {
    MessageList._activeInstance = this; // always keep current
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    // Cache the stream to prevent recreation on parent rebuilds (avoids image flicker)
    final streamKey = widget.channelId ?? widget.conversationId ?? 0;
    if (_messageStream == null || _streamChannelId != streamKey) {
      if (widget.channelId != null) {
        _messageStream = db.messagesDao.watchChannelMessages(widget.channelId!);
      } else if (widget.conversationId != null) {
        _messageStream = db.messagesDao.watchConversationMessages(widget.conversationId!);
      }
      _streamChannelId = streamKey;
    }

    return StreamBuilder<List<Message>>(
      stream: _messageStream,
      builder: (context, snapshot) {
        final messages = snapshot.data ?? [];
        _lastMessages = messages; // cache for scroll-to lookup

        if (messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 68, height: 68,
                  decoration: BoxDecoration(color: c.gray600, shape: BoxShape.circle),
                  child: Center(child: Text('#', style: TextStyle(color: c.gray400, fontSize: 32, fontWeight: FontWeight.bold))),
                ),
                const SizedBox(height: 16),
                Text('Welcome to the channel!', style: TextStyle(color: c.gray50, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('This is the start of this channel.', style: TextStyle(color: c.gray500, fontSize: 14)),
              ],
            ),
          );
        }

        return ListView.builder(
          controller: _scrollController,
          reverse: true,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final msg = messages[index];
            final prevMsg = index < messages.length - 1 ? messages[index + 1] : null;
            final isGrouped = prevMsg != null &&
                prevMsg.nostrAuthorPubkey == msg.nostrAuthorPubkey &&
                msg.createdAt.difference(prevMsg.createdAt).inMinutes.abs() < 5 &&
                !(msg.systemMessage);
            final isOwn = msg.nostrAuthorPubkey == null || msg.nostrAuthorPubkey == auth.publicKeyHex;

            if (msg.systemMessage) {
              return _SystemMessage(message: msg, colors: c);
            }

            final isHighlighted = _highlightedEventId != null && msg.nostrEventId == _highlightedEventId;

            return _HighlightWrap(
              key: msg.nostrEventId != null ? GlobalObjectKey('msg-${msg.nostrEventId}') : null,
              highlighted: isHighlighted,
              accentColor: c.accent,
              child: FutureBuilder<_AuthorInfo>(
              future: _resolveAuthor(msg.nostrAuthorPubkey ?? auth.publicKeyHex ?? ''),
              builder: (context, authorSnap) {
                final author = authorSnap.data ?? _AuthorInfo(
                  name: msg.nostrAuthorPubkey != null ? '${msg.nostrAuthorPubkey!.substring(0, 8)}...' : 'Unknown',
                  avatarUrl: null,
                );

                return _ChannelMessage(
                  message: msg,
                  isGrouped: isGrouped,
                  isOwn: isOwn,
                  authorName: author.name,
                  authorAvatarUrl: author.avatarUrl,
                  colors: c,
                  db: db,
                  authPubkey: auth.publicKeyHex,
                  onReply: widget.onReply != null
                      ? () {
                          final preview = (msg.content ?? '').length > 80
                              ? '${msg.content!.substring(0, 80)}...'
                              : msg.content ?? '';
                          widget.onReply!(msg, author.name, preview);
                        }
                      : null,
                  onPin: () => _handlePin(msg),
                  onDelete: isOwn ? () => _confirmDelete(context, msg, c) : null,
                  onEdit: isOwn ? () => widget.onEdit?.call(msg) : null,
                  onReaction: (emoji) => _handleReaction(msg, emoji),
                  onAuthorTap: msg.nostrAuthorPubkey != null ? () {
                    showUserProfileCard(context, ref, msg.nostrAuthorPubkey!);
                  } : null,
                  isDm: widget.conversationId != null,
                  authorRoleColor: author.roleColor,
                );
              },
            ),
            );
          },
        );
      },
    );
  }

  void _confirmDelete(BuildContext context, Message msg, InfernoColors c) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.gray800,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Delete Message', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Are you sure you want to delete this message? This cannot be undone.',
                style: TextStyle(color: c.gray400, fontSize: 14)),
              if (msg.content != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                  child: Text(msg.content!, style: TextStyle(color: c.gray200, fontSize: 13), maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                    onPressed: () { Navigator.pop(ctx); _handleDelete(msg); },
                    child: const Text('Delete', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

}

class _AuthorInfo {
  final String name;
  final String? avatarUrl;
  final Color? roleColor;
  _AuthorInfo({required this.name, this.avatarUrl, this.roleColor});
}

class _ChannelMessage extends StatefulWidget {
  final Message message;
  final bool isGrouped;
  final bool isOwn;
  final String authorName;
  final String? authorAvatarUrl;
  final InfernoColors colors;
  final InfernoDatabase db;
  final String? authPubkey;
  final VoidCallback? onReply;
  final VoidCallback? onPin;
  final VoidCallback? onDelete;
  final void Function(String emoji) onReaction;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onEdit;
  final bool isDm;
  final Color? authorRoleColor;

  const _ChannelMessage({
    required this.message,
    required this.isGrouped,
    required this.isOwn,
    required this.authorName,
    this.authorAvatarUrl,
    required this.colors,
    required this.db,
    this.authPubkey,
    this.onReply,
    this.onPin,
    this.onDelete,
    required this.onReaction,
    this.onAuthorTap,
    this.onEdit,
    this.isDm = false,
    this.authorRoleColor,
  });

  @override
  State<_ChannelMessage> createState() => _ChannelMessageState();
}

class _ChannelMessageState extends State<_ChannelMessage> {
  bool _hovering = false;

  void _showContextMenu(TapDownDetails details) {
    final c = widget.colors;
    final pos = details.globalPosition;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      color: c.gray900,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: c.gray700)),
      items: [
        _ctxItem('copy', 'Copy Text', Icons.copy, c),
        _ctxItem('reply', 'Reply', Icons.reply, c),
        _ctxItem('pin', widget.message.pinned == true ? 'Unpin' : 'Pin', Icons.push_pin_outlined, c),
        if (widget.isOwn) _ctxItem('edit', 'Edit', Icons.edit_outlined, c),
        if (widget.isOwn) _ctxItem('delete', 'Delete', Icons.delete_outline, c, danger: true),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'copy':
          if (widget.message.content != null) Clipboard.setData(ClipboardData(text: widget.message.content!));
        case 'reply': widget.onReply?.call();
        case 'pin': widget.onPin?.call();
        case 'edit': widget.onEdit?.call();
        case 'delete': widget.onDelete?.call();
      }
    });
  }

  PopupMenuItem<String> _ctxItem(String value, String label, IconData icon, InfernoColors c, {bool danger = false}) {
    return PopupMenuItem(value: value, child: Row(children: [
      Icon(icon, size: 16, color: danger ? c.accent : c.gray400),
      const SizedBox(width: 10),
      Text(label, style: TextStyle(color: danger ? c.accent : c.gray200, fontSize: 14)),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final msg = widget.message;
    // In DMs/group chats, don't color names — use neutral white for all
    // In server channels, own messages use accent color
    // Use role color for author name — matches Rails role_color_for(server)
    final nameColor = widget.authorRoleColor ?? c.gray50;

    return GestureDetector(
      onSecondaryTapDown: _showContextMenu,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.only(top: widget.isGrouped ? 2 : 12, bottom: widget.isGrouped ? 2 : 12, left: 14, right: 16),
          decoration: BoxDecoration(
            gradient: _hovering ? LinearGradient(
              colors: [c.accent.withValues(alpha: 0.06), Colors.transparent],
              begin: Alignment.centerLeft, end: Alignment.centerRight,
            ) : null,
            border: Border(left: BorderSide(
              color: _hovering ? c.accent.withValues(alpha: 0.4) : Colors.transparent,
              width: 2,
            )),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Avatar column
                  SizedBox(
                    width: 40,
                    child: widget.isGrouped
                        ? (_hovering
                            ? Center(child: Text(DateFormat('h:mm a').format(msg.createdAt.toLocal()), style: TextStyle(color: c.gray500, fontSize: 10)))
                            : const SizedBox())
                        : CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.transparent,
                            backgroundImage: widget.authorAvatarUrl != null && widget.authorAvatarUrl!.startsWith('http') ? NetworkImage(widget.authorAvatarUrl!) : null,
                            child: (widget.authorAvatarUrl == null || !widget.authorAvatarUrl!.startsWith('http'))
                                ? Text(widget.authorName[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 16))
                                : null,
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!widget.isGrouped)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(children: [
                              MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  onTap: widget.onAuthorTap,
                                  child: Text(widget.authorName, style: TextStyle(color: nameColor, fontWeight: FontWeight.w600, fontSize: 14)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(DateFormat('MM/dd/yyyy h:mm a').format(msg.createdAt.toLocal()), style: TextStyle(color: c.gray500, fontSize: 12)),
                              if (msg.editedAt != null) ...[
                                const SizedBox(width: 4),
                                Text('(edited)', style: TextStyle(color: c.gray500, fontSize: 11)),
                              ],
                            ]),
                          ),
                        if (msg.pinned == true)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Row(children: [
                              Icon(Icons.push_pin, size: 12, color: c.idle),
                              const SizedBox(width: 4),
                              Text('Pinned', style: TextStyle(color: c.idle, fontSize: 12)),
                            ]),
                          ),
                        // Reply indicator
                        if (msg.parentId != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(children: [
                              Icon(Icons.reply, size: 14, color: c.gray500),
                              const SizedBox(width: 4),
                              Text('Reply to a message', style: TextStyle(color: c.gray500, fontSize: 12, fontStyle: FontStyle.italic)),
                            ]),
                          ),
                        if (msg.content != null && msg.content!.isNotEmpty)
                          MessageContent(content: msg.content!, colors: c, isSpoiler: msg.spoiler),
                        // Reactions
                        StreamBuilder<List<Reaction>>(
                          stream: widget.db.messagesDao.watchReactions(msg.id),
                          builder: (context, snap) {
                            final reactions = snap.data ?? [];
                            if (reactions.isEmpty) return const SizedBox.shrink();
                            // Group by emoji
                            final grouped = <String, int>{};
                            final own = <String>{};
                            for (final r in reactions) {
                              if (r.emoji == null) continue;
                              grouped[r.emoji!] = (grouped[r.emoji!] ?? 0) + 1;
                              // Check if own (userId == 1 or match pubkey)
                              if (r.userId == 1) own.add(r.emoji!);
                            }
                            return ReactionBar(
                              reactions: grouped,
                              ownReactions: own,
                              onToggle: widget.onReaction,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (_hovering)
                Positioned(
                  top: widget.isGrouped ? -12 : 4,
                  right: 0,
                  child: _MessageActions(
                    colors: c,
                    isOwn: widget.isOwn,
                    isPinned: msg.pinned == true,
                    onReply: widget.onReply,
                    onPin: widget.onPin,
                    onEdit: widget.isOwn ? () => widget.onEdit?.call() : null,
                    onDelete: widget.onDelete,
                    onReact: () {
                      // Quick react with thumbs up
                      widget.onReaction('\u{1F44D}');
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageActions extends StatelessWidget {
  final InfernoColors colors;
  final bool isOwn;
  final bool isPinned;
  final VoidCallback? onReply;
  final VoidCallback? onPin;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onReact;

  const _MessageActions({
    required this.colors, required this.isOwn, required this.isPinned,
    this.onReply, this.onPin, this.onEdit, this.onDelete, this.onReact,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: colors.gray800, borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.gray700),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _ActionButton(icon: Icons.emoji_emotions_outlined, tooltip: 'React', colors: colors, onTap: onReact),
        _ActionButton(icon: Icons.reply, tooltip: 'Reply', colors: colors, onTap: onReply),
        _ActionButton(icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined, tooltip: isPinned ? 'Unpin' : 'Pin', colors: colors, onTap: onPin),
        if (isOwn) _ActionButton(icon: Icons.edit_outlined, tooltip: 'Edit', colors: colors, onTap: onEdit),
        if (isOwn) _ActionButton(icon: Icons.delete_outline, tooltip: 'Delete', colors: colors, onTap: onDelete, hoverColor: colors.accent),
      ]),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final InfernoColors colors;
  final Color? hoverColor;
  final VoidCallback? onTap;
  const _ActionButton({required this.icon, required this.tooltip, required this.colors, this.hoverColor, this.onTap});

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(widget.icon, size: 16,
              color: _hovering ? (widget.hoverColor ?? widget.colors.gray200) : widget.colors.gray400),
          ),
        ),
      ),
    );
  }
}

/// Flashing highlight wrapper for scroll-to-message — no layout shift
class _HighlightWrap extends StatefulWidget {
  final Widget child;
  final bool highlighted;
  final Color accentColor;
  const _HighlightWrap({super.key, required this.child, required this.highlighted, required this.accentColor});
  @override
  State<_HighlightWrap> createState() => _HighlightWrapState();
}

class _HighlightWrapState extends State<_HighlightWrap> with SingleTickerProviderStateMixin {
  AnimationController? _flashController;

  @override
  void initState() {
    super.initState();
    if (widget.highlighted) _startFlash();
  }

  @override
  void didUpdateWidget(_HighlightWrap old) {
    super.didUpdateWidget(old);
    if (widget.highlighted && !old.highlighted) {
      _startFlash();
    } else if (!widget.highlighted && old.highlighted) {
      _flashController?.stop();
      _flashController?.dispose();
      _flashController = null;
      if (mounted) setState(() {});
    }
  }

  void _startFlash() {
    _flashController?.dispose();
    _flashController = AnimationController(vsync: this, duration: const Duration(milliseconds: 500))
      ..addListener(() { if (mounted) setState(() {}); })
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _flashController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.highlighted || _flashController == null) return widget.child;

    return AnimatedBuilder(
      animation: _flashController!,
      builder: (context, child) {
        final opacity = _flashController!.value * 0.15;
        return Container(
          decoration: BoxDecoration(
            color: widget.accentColor.withValues(alpha: opacity),
            // No border — avoid layout shift. Use boxShadow for the left accent glow instead.
            boxShadow: [
              BoxShadow(
                color: widget.accentColor.withValues(alpha: _flashController!.value * 0.4),
                blurRadius: 4,
                offset: const Offset(-2, 0),
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SystemMessage extends StatelessWidget {
  final Message message;
  final InfernoColors colors;
  const _SystemMessage({required this.message, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 16),
      child: Row(children: [
        Icon(Icons.arrow_forward, size: 16, color: colors.online),
        const SizedBox(width: 8),
        Expanded(child: Text(message.content ?? '', style: TextStyle(color: colors.gray400, fontSize: 14))),
        const SizedBox(width: 8),
        Text(DateFormat('MM/dd/yyyy h:mm a').format(message.createdAt.toLocal()), style: TextStyle(color: colors.gray500, fontSize: 12)),
      ]),
    );
  }
}
