import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/all_themes.dart';

class MessageList extends ConsumerStatefulWidget {
  final int channelId;
  const MessageList({super.key, required this.channelId});

  @override
  ConsumerState<MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<MessageList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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

            if (msg.systemMessage) {
              return _SystemMessage(message: msg, colors: c);
            }

            return _ChannelMessage(
              message: msg,
              isGrouped: isGrouped,
              isOwn: msg.nostrAuthorPubkey == null || msg.nostrAuthorPubkey == auth.publicKeyHex,
              colors: c,
            );
          },
        );
      },
    );
  }
}

class _ChannelMessage extends StatefulWidget {
  final Message message;
  final bool isGrouped;
  final bool isOwn;
  final InfernoColors colors;

  const _ChannelMessage({
    required this.message,
    required this.isGrouped,
    required this.isOwn,
    required this.colors,
  });

  @override
  State<_ChannelMessage> createState() => _ChannelMessageState();
}

class _ChannelMessageState extends State<_ChannelMessage> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final msg = widget.message;
    final authorName = msg.nostrAuthorPubkey != null
        ? '${msg.nostrAuthorPubkey!.substring(0, 8)}...'
        : 'You';
    // Owner gets accent color, others get gray-50
    final nameColor = widget.isOwn ? c.accent : c.gray50;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: EdgeInsets.only(
          top: widget.isGrouped ? 1 : 16,
          bottom: 1,
          left: 16,
          right: 16,
        ),
        decoration: BoxDecoration(
          color: _hovering ? c.gray700.withValues(alpha: 0.5) : Colors.transparent,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar column (40px)
                SizedBox(
                  width: 40,
                  child: widget.isGrouped
                      ? (_hovering
                          ? Center(
                              child: Text(
                                DateFormat('h:mm a').format(msg.createdAt),
                                style: TextStyle(color: c.gray500, fontSize: 10),
                              ),
                            )
                          : const SizedBox())
                      : CircleAvatar(
                          radius: 20,
                          backgroundColor: c.gray600,
                          child: Text(
                            authorName[0].toUpperCase(),
                            style: TextStyle(color: c.gray200, fontSize: 16),
                          ),
                        ),
                ),
                const SizedBox(width: 16),
                // Content column
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Author + timestamp (only for non-grouped)
                      if (!widget.isGrouped)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              Text(
                                authorName,
                                style: TextStyle(color: nameColor, fontWeight: FontWeight.w600, fontSize: 14),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                DateFormat('MM/dd/yyyy h:mm a').format(msg.createdAt),
                                style: TextStyle(color: c.gray500, fontSize: 12),
                              ),
                              if (msg.editedAt != null) ...[
                                const SizedBox(width: 4),
                                Text('(edited)', style: TextStyle(color: c.gray500, fontSize: 11)),
                              ],
                            ],
                          ),
                        ),
                      // Pinned indicator
                      if (msg.pinned == true)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              Icon(Icons.push_pin, size: 12, color: c.idle),
                              const SizedBox(width: 4),
                              Text('Pinned', style: TextStyle(color: c.idle, fontSize: 12)),
                            ],
                          ),
                        ),
                      // Message content
                      if (msg.content != null && msg.content!.isNotEmpty)
                        Text(
                          msg.content!,
                          style: TextStyle(color: c.gray200, fontSize: 15, height: 1.4),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // Hover action buttons
            if (_hovering)
              Positioned(
                top: widget.isGrouped ? -12 : 4,
                right: 0,
                child: _MessageActions(colors: c),
              ),
          ],
        ),
      ),
    );
  }
}

class _MessageActions extends StatelessWidget {
  final InfernoColors colors;
  const _MessageActions({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: colors.gray800,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: colors.gray700),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionButton(icon: Icons.emoji_emotions_outlined, tooltip: 'React', colors: colors),
          _ActionButton(icon: Icons.reply, tooltip: 'Reply', colors: colors),
          _ActionButton(icon: Icons.push_pin_outlined, tooltip: 'Pin', colors: colors),
          _ActionButton(icon: Icons.edit_outlined, tooltip: 'Edit', colors: colors),
          _ActionButton(icon: Icons.delete_outline, tooltip: 'Delete', colors: colors, hoverColor: colors.accent),
        ],
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final InfernoColors colors;
  final Color? hoverColor;
  const _ActionButton({required this.icon, required this.tooltip, required this.colors, this.hoverColor});

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
          onTap: () {},
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hovering ? (widget.hoverColor ?? widget.colors.gray200) : widget.colors.gray400,
            ),
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
      child: Row(
        children: [
          Icon(Icons.arrow_forward, size: 16, color: colors.online),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.content ?? '',
              style: TextStyle(color: colors.gray400, fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            DateFormat('MM/dd/yyyy h:mm a').format(message.createdAt),
            style: TextStyle(color: colors.gray500, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
