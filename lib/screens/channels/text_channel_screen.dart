import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../providers/servers_provider.dart';
import '../../theme/all_themes.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../widgets/typing_indicator.dart';
import '../../providers/realtime_provider.dart';
import '../../services/backfill_service.dart';
import '../../services/dm_service.dart';
import '../main_shell.dart';

class TextChannelScreen extends ConsumerStatefulWidget {
  final String channelPublicId;
  final String serverPublicId;

  const TextChannelScreen({
    super.key,
    required this.channelPublicId,
    required this.serverPublicId,
  });

  @override
  ConsumerState<TextChannelScreen> createState() => _TextChannelScreenState();
}

class _TextChannelScreenState extends ConsumerState<TextChannelScreen> {
  Channel? _channel;

  // Reply state
  String? _replyMessageId;
  String? _replyAuthorName;
  String? _replyPreview;

  @override
  void initState() {
    super.initState();
    _loadChannel();
  }

  @override
  void didUpdateWidget(TextChannelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelPublicId != widget.channelPublicId) {
      _loadChannel();
      // Clear reply when switching channels
      setState(() {
        _replyMessageId = null;
        _replyAuthorName = null;
        _replyPreview = null;
      });
    }
  }

  Future<void> _loadChannel() async {
    final db = ref.read(databaseProvider);
    final ch = await db.serversDao.getChannelByPublicId(widget.channelPublicId);
    if (mounted) setState(() => _channel = ch);

    // Trigger backfill from relays (matches Rails: Thread.new { NostrHistoryFetcher.fetch_channel(channel) })
    if (ch?.nostrGroupId != null) {
      _backfillChannel(ch!);
    }
  }

  Future<void> _backfillChannel(Channel channel) async {
    if (channel.nostrGroupId == null) return;
    final db = ref.read(databaseProvider);
    final pool = ref.read(relayPoolProvider);
    final auth = ref.read(authServiceProvider);
    final groupMsgSvc = ref.read(groupMessageServiceProvider);
    final dmSvc = DmService(db, pool);
    final backfill = BackfillService(db, pool, groupMsgSvc, dmSvc);
    try {
      await backfill.backfillChannel(
        channelGroupId: channel.nostrGroupId!,
        backfillDays: 30,
        privateKeyHex: auth.privateKeyHex,
      );
    } catch (e) {
      debugPrint('[Backfill] Error backfilling ${channel.name}: $e');
    }
  }

  Future<void> _sendMessage(String content) async {
    if (_channel == null) return;
    final authService = ref.read(authServiceProvider);
    if (authService.privateKeyHex == null) return;

    final groupMsgService = ref.read(groupMessageServiceProvider);
    await groupMsgService.sendMessage(
      privateKeyHex: authService.privateKeyHex!,
      publicKeyHex: authService.publicKeyHex!,
      channel: _channel!,
      content: content,
      parentEventId: _replyMessageId,
    );

    // Clear reply after sending
    if (mounted) {
      setState(() {
        _replyMessageId = null;
        _replyAuthorName = null;
        _replyPreview = null;
      });
    }
  }

  void _setReply(Message message, String authorName, String preview) {
    setState(() {
      _replyMessageId = message.nostrEventId;
      _replyAuthorName = authorName;
      _replyPreview = preview;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_channel == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final c = Theme.of(context).extension<InfernoColors>()!;

    return Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: c.gray700,
            border: Border(bottom: BorderSide(color: c.gray900)),
          ),
          child: Row(
            children: [
              Icon(
                _channel!.encrypted ? Icons.lock : Icons.tag,
                size: 20,
                color: c.gray400,
              ),
              const SizedBox(width: 8),
              Text(
                _channel!.name,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              if (_channel!.topic != null && _channel!.topic!.isNotEmpty) ...[
                const SizedBox(width: 12),
                Container(width: 1, height: 24, color: c.gray600),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _channel!.topic!,
                    style: TextStyle(color: c.gray400, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
              // Header action buttons
              _HeaderAction(icon: Icons.push_pin_outlined, tooltip: 'Pinned Messages', colors: c, onTap: () {
                _showPinnedMessages(context, c);
              }),
              _HeaderAction(icon: Icons.people_outline, tooltip: 'Member List', colors: c, onTap: () {
                // Toggle member list via MainShell
                _toggleMemberList(context);
              }),
              const SizedBox(width: 4),
              // Search field
              Container(
                width: 160,
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: c.gray900,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text('Search', style: TextStyle(color: c.gray500, fontSize: 13))),
                    Icon(Icons.search, size: 16, color: c.gray500),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Messages
        Expanded(
          child: MessageList(
            channelId: _channel!.id,
            channel: _channel,
            onReply: _setReply,
          ),
        ),
        // Typing indicator
        if (_channel!.nostrGroupId != null)
          Consumer(builder: (context, ref, _) {
            final typingAsync = ref.watch(typingUsersProvider(_channel!.nostrGroupId!));
            return typingAsync.when(
              data: (users) {
                // Filter out own pubkey
                final auth = ref.read(authServiceProvider);
                final others = users.where((u) => u != auth.publicKeyHex).toList();
                return TypingIndicator(typingUsers: others);
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            );
          }),
        // Reply bar
        if (_replyAuthorName != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: c.gray700,
              border: Border(top: BorderSide(color: c.gray600)),
            ),
            child: Row(
              children: [
                Icon(Icons.reply, size: 16, color: c.accent),
                const SizedBox(width: 8),
                Text('Replying to ', style: TextStyle(color: c.gray400, fontSize: 13)),
                Text(_replyAuthorName!, style: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _replyPreview ?? '',
                    style: TextStyle(color: c.gray500, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() {
                    _replyMessageId = null;
                    _replyAuthorName = null;
                    _replyPreview = null;
                  }),
                  child: Icon(Icons.close, size: 16, color: c.gray400),
                ),
              ],
            ),
          ),
        // Input
        MessageInput(
          onSend: _sendMessage,
          channelName: _channel!.name,
          onTyping: () {
            if (_channel?.nostrGroupId == null) return;
            final auth = ref.read(authServiceProvider);
            if (auth.privateKeyHex == null) return;
            final typingSvc = ref.read(typingServiceProvider);
            typingSvc.sendTyping(
              privateKeyHex: auth.privateKeyHex!,
              publicKeyHex: auth.publicKeyHex!,
              channelGroupId: _channel!.nostrGroupId!,
            );
          },
        ),
      ],
    );
  }

  void _toggleMemberList(BuildContext context) {
    // Find the MainShell ancestor and toggle its member list
    final mainShell = context.findAncestorStateOfType<MainShellState>();
    mainShell?.toggleMemberList();
  }

  void _showPinnedMessages(BuildContext context, InfernoColors c) {
    if (_channel == null) return;
    showDialog(
      context: context,
      builder: (ctx) => _PinnedMessagesDialog(channelId: _channel!.id, colors: c),
    );
  }
}

class _PinnedMessagesDialog extends ConsumerWidget {
  final int channelId;
  final InfernoColors colors;
  const _PinnedMessagesDialog({required this.channelId, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 500,
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        decoration: BoxDecoration(
          color: colors.gray800,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.gray700.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.push_pin, size: 20, color: colors.idle),
                  const SizedBox(width: 8),
                  Text('Pinned Messages', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close, size: 20, color: colors.gray400),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: colors.gray700),
            Flexible(
              child: StreamBuilder<List<Message>>(
                stream: db.messagesDao.watchPinnedMessages(channelId),
                builder: (context, snapshot) {
                  final pinned = snapshot.data ?? [];
                  if (pinned.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text('No pinned messages', style: TextStyle(color: colors.gray500, fontSize: 14)),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: pinned.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final msg = pinned[index];
                      final author = msg.nostrAuthorPubkey != null
                          ? '${msg.nostrAuthorPubkey!.substring(0, 8)}...'
                          : 'Unknown';
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.gray900,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(author, style: TextStyle(color: colors.accent, fontWeight: FontWeight.w600, fontSize: 13)),
                            const SizedBox(height: 4),
                            Text(msg.content ?? '', style: TextStyle(color: colors.gray200, fontSize: 14)),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _HeaderAction({required this.icon, required this.tooltip, required this.colors, required this.onTap});

  @override
  State<_HeaderAction> createState() => _HeaderActionState();
}

class _HeaderActionState extends State<_HeaderAction> {
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
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(widget.icon, size: 20,
              color: _hovering ? widget.colors.gray200 : widget.colors.gray400),
          ),
        ),
      ),
    );
  }
}
