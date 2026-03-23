import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/servers_provider.dart';
import '../providers/realtime_provider.dart';
import '../theme/all_themes.dart';
import 'reaction_bar.dart';
import 'message_content.dart';

typedef MessageReplyCallback = void Function(Message message, String authorName, String preview);

class MessageList extends ConsumerStatefulWidget {
  final int channelId;
  final MessageReplyCallback? onReply;
  final Channel? channel;
  const MessageList({super.key, required this.channelId, this.onReply, this.channel});

  @override
  ConsumerState<MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<MessageList> {
  final ScrollController _scrollController = ScrollController();
  // Cache resolved author info: pubkey -> {name, avatarUrl}
  final Map<String, _AuthorInfo> _authorCache = {};

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<_AuthorInfo> _resolveAuthor(String pubkey) async {
    if (_authorCache.containsKey(pubkey)) return _authorCache[pubkey]!;

    final db = ref.read(databaseProvider);

    // Try contacts table first
    final contact = await db.contactsDao.getByPubkey(pubkey);
    if (contact != null) {
      final info = _AuthorInfo(
        name: contact.displayName ?? contact.username ?? '${pubkey.substring(0, 8)}...',
        avatarUrl: contact.avatarUrl,
      );
      _authorCache[pubkey] = info;
      return info;
    }

    // Try remote_members table
    final members = await (db.select(db.remoteMembers)
          ..where((m) => m.pubkey.equals(pubkey))
          ..limit(1))
        .get();
    if (members.isNotEmpty) {
      final m = members.first;
      final info = _AuthorInfo(
        name: m.displayName ?? m.username ?? '${pubkey.substring(0, 8)}...',
        avatarUrl: m.avatarUrl,
      );
      _authorCache[pubkey] = info;
      return info;
    }

    // Fallback to truncated pubkey
    final info = _AuthorInfo(name: '${pubkey.substring(0, 8)}...', avatarUrl: null);
    _authorCache[pubkey] = info;
    return info;
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

  Future<void> _handleEdit(Message msg, String newContent) async {
    if (widget.channel == null || msg.nostrEventId == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final svc = ref.read(groupMessageServiceProvider);
    await svc.editMessage(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      channel: widget.channel!,
      originalEventId: msg.nostrEventId!,
      newContent: newContent,
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
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return StreamBuilder<List<Message>>(
      stream: db.messagesDao.watchChannelMessages(widget.channelId),
      builder: (context, snapshot) {
        final messages = snapshot.data ?? [];

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

            return FutureBuilder<_AuthorInfo>(
              future: msg.nostrAuthorPubkey != null
                  ? _resolveAuthor(msg.nostrAuthorPubkey!)
                  : Future.value(_AuthorInfo(name: 'You', avatarUrl: null)),
              builder: (context, authorSnap) {
                final author = authorSnap.data ?? _AuthorInfo(
                  name: msg.nostrAuthorPubkey != null ? '${msg.nostrAuthorPubkey!.substring(0, 8)}...' : 'You',
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
                  onEdit: isOwn ? () => _showEditDialog(context, msg, c) : null,
                  onReaction: (emoji) => _handleReaction(msg, emoji),
                );
              },
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

  void _showEditDialog(BuildContext context, Message msg, InfernoColors c) {
    final controller = TextEditingController(text: msg.content ?? '');
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 500,
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
              Text('Edit Message', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 5, minLines: 2,
                style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  fillColor: c.gray900, filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      final newContent = controller.text.trim();
                      if (newContent.isNotEmpty && newContent != msg.content) {
                        Navigator.pop(ctx);
                        _handleEdit(msg, newContent);
                      }
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ).then((_) => controller.dispose());
  }
}

class _AuthorInfo {
  final String name;
  final String? avatarUrl;
  _AuthorInfo({required this.name, this.avatarUrl});
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
  final VoidCallback? onEdit;
  final void Function(String emoji) onReaction;

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
    this.onEdit,
    required this.onReaction,
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
    final nameColor = widget.isOwn ? c.accent : c.gray50;

    return GestureDetector(
      onSecondaryTapDown: _showContextMenu,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Container(
          padding: EdgeInsets.only(top: widget.isGrouped ? 1 : 16, bottom: 1, left: 16, right: 16),
          decoration: BoxDecoration(color: _hovering ? c.gray700.withValues(alpha: 0.5) : Colors.transparent),
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
                            ? Center(child: Text(DateFormat('h:mm a').format(msg.createdAt), style: TextStyle(color: c.gray500, fontSize: 10)))
                            : const SizedBox())
                        : CircleAvatar(
                            radius: 20,
                            backgroundColor: c.gray600,
                            backgroundImage: widget.authorAvatarUrl != null ? NetworkImage(widget.authorAvatarUrl!) : null,
                            child: widget.authorAvatarUrl == null
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
                              Text(widget.authorName, style: TextStyle(color: nameColor, fontWeight: FontWeight.w600, fontSize: 14)),
                              const SizedBox(width: 8),
                              Text(DateFormat('MM/dd/yyyy h:mm a').format(msg.createdAt), style: TextStyle(color: c.gray500, fontSize: 12)),
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
                          MessageContent(content: msg.content!, colors: c),
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
                    onEdit: widget.onEdit,
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
        Text(DateFormat('MM/dd/yyyy h:mm a').format(message.createdAt), style: TextStyle(color: colors.gray500, fontSize: 12)),
      ]),
    );
  }
}
