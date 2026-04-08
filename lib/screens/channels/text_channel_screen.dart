import 'dart:async';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../providers/servers_provider.dart';
import '../../providers/unread_provider.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../widgets/typing_indicator.dart';
import '../../providers/realtime_provider.dart';
import '../../services/backfill_service.dart';
import '../../services/blossom_client.dart';
import '../../services/content_safety_service.dart';
import '../../services/dm_service.dart';
import '../main_shell.dart';

class TextChannelScreen extends ConsumerStatefulWidget {
  final String channelPublicId;
  final String serverPublicId;
  final bool isActive;

  const TextChannelScreen({
    super.key,
    required this.channelPublicId,
    required this.serverPublicId,
    this.isActive = true,
  });

  @override
  ConsumerState<TextChannelScreen> createState() => _TextChannelScreenState();
}

class _TextChannelScreenState extends ConsumerState<TextChannelScreen> {
  Channel? _channel;
  StreamSubscription<Channel?>? _channelSub;
  bool _initialLoadDone = false;

  // Reply state
  String? _replyMessageId;
  String? _replyAuthorName;
  String? _replyPreview;

  // Edit state — when editing, the message input is pre-filled and sends an edit instead of new message
  String? _editMessageEventId;
  String? _editOriginalContent;

  // Custom emoji map for this server: name -> url
  Map<String, String> _customEmojis = {};

  // NSFW gate: track which channels the user has acknowledged
  static final Set<String> _nsfwAcceptedChannels = {};
  bool get _isNsfwGated => _channel?.nsfw == true && !_nsfwAcceptedChannels.contains(_channel!.publicId);

  @override
  void initState() {
    super.initState();
    _watchChannel();
  }

  @override
  void didUpdateWidget(TextChannelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelPublicId != widget.channelPublicId) {
      _initialLoadDone = false;
      _watchChannel();
      // Clear reply/edit when switching channels
      setState(() {
        _replyMessageId = null;
        _replyAuthorName = null;
        _replyPreview = null;
        _editMessageEventId = null;
        _editOriginalContent = null;
      });
    }
  }

  @override
  void deactivate() {
    // Update read timestamp on leave so messages seen during this session are marked read
    // and clear active channel so unread badges reappear when navigating away
    // Must happen in deactivate() — ref is unavailable in dispose()
    if (_channel != null) {
      final db = ref.read(databaseProvider);
      db.messagesDao.upsertChannelRead(_channel!.id, localUserId);
      final channelId = _channel!.id;
      final activeId = ref.read(activeChannelIdProvider);
      final notifier = ref.read(activeChannelIdProvider.notifier);
      // Defer provider modification to avoid "modified during build" error
      if (activeId == channelId) {
        Future(() => notifier.state = null);
      }
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _channelSub?.cancel();
    super.dispose();
  }

  static const _backfillInterval = Duration(minutes: 10);

  void _watchChannel() {
    _channelSub?.cancel();
    final db = ref.read(databaseProvider);
    final query = db.select(db.channels)..where((c) => c.publicId.equals(widget.channelPublicId));
    _channelSub = query.watchSingleOrNull().listen((ch) {
      if (!mounted) return;
      setState(() => _channel = ch);
      // Run one-time setup only on first emission (or channel switch)
      if (ch != null && !_initialLoadDone) {
        _initialLoadDone = true;
        _onChannelFirstLoad(ch);
      }
    });
  }

  Future<void> _onChannelFirstLoad(Channel ch) async {
    final db = ref.read(databaseProvider);

    // Mark channel as read and set as active (clear DM active)
    ref.read(activeChannelIdProvider.notifier).state = ch.id;
    ref.read(activeConversationIdProvider.notifier).state = null;
    await db.messagesDao.upsertChannelRead(ch.id, localUserId);

    // Load custom emojis for this server
    final emojis = await (db.select(db.serverEmojis)
      ..where((e) => e.serverId.equals(ch.serverId)))
      .get();
    if (mounted) {
      setState(() {
        _customEmojis = {for (final e in emojis) if (e.url != null) e.name: e.url!};
      });
    }

    // Backfill only if not recently backfilled (persisted across restarts)
    if (ch.nostrGroupId != null) {
      final shouldBackfill = ch.lastBackfilledAt == null ||
          DateTime.now().difference(ch.lastBackfilledAt!) > _backfillInterval;
      if (shouldBackfill) {
        _backfillChannel(ch);
      }
    }
  }

  Future<void> _backfillChannel(Channel channel) async {
    if (channel.nostrGroupId == null || !mounted) return;
    final db = ref.read(databaseProvider);
    final pool = ref.read(relayPoolProvider);
    final auth = ref.read(authServiceProvider);
    final groupMsgSvc = ref.read(groupMessageServiceProvider);
    final dmSvc = DmService(db, pool);
    final contentSafety = ContentSafetyService(db);
    final backfill = BackfillService(db, pool, groupMsgSvc, dmSvc, contentSafety);
    try {
      await backfill.backfillChannel(
        channelGroupId: channel.nostrGroupId!,
        backfillDays: 30,
        privateKeyHex: auth.privateKeyHex,
      );
      // Stamp last backfill time in DB so we don't re-backfill on restart
      await (db.update(db.channels)..where((c) => c.id.equals(channel.id)))
          .write(ChannelsCompanion(lastBackfilledAt: Value(DateTime.now())));
      // Re-mark as read after backfill (user is viewing, so backfilled messages are "read")
      await db.messagesDao.upsertChannelRead(channel.id, localUserId);
    } catch (e) {
      debugPrint('[Backfill] Error backfilling ${channel.name}: $e');
    }
  }

  Future<void> _sendMessage(String content, {bool spoiler = false, List<String>? fileUrls}) async {
    if (_channel == null) return;
    final authService = ref.read(authServiceProvider);
    if (authService.privateKeyHex == null) return;

    final groupMsgService = ref.read(groupMessageServiceProvider);

    if (_editMessageEventId != null) {
      // Edit mode — send edit instead of new message
      debugPrint('[Edit] Editing message $_editMessageEventId with new content: $content');
      await groupMsgService.editMessage(
        privateKeyHex: authService.privateKeyHex!,
        publicKeyHex: authService.publicKeyHex!,
        channel: _channel!,
        originalEventId: _editMessageEventId!,
        newContent: content,
      );
    } else {
      // Normal send
      await groupMsgService.sendMessage(
        privateKeyHex: authService.privateKeyHex!,
        publicKeyHex: authService.publicKeyHex!,
        channel: _channel!,
        content: content,
        parentEventId: _replyMessageId,
        spoiler: spoiler,
      );
    }

    // Clear reply/edit after sending
    if (mounted) {
      setState(() {
        _replyMessageId = null;
        _replyAuthorName = null;
        _replyPreview = null;
        _editMessageEventId = null;
        _editOriginalContent = null;
      });
    }
  }

  void _setReply(Message message, String authorName, String preview) {
    setState(() {
      _replyMessageId = message.nostrEventId;
      _replyAuthorName = authorName;
      _replyPreview = preview;
      // Cancel any active edit
      _editMessageEventId = null;
      _editOriginalContent = null;
    });
  }

  void _setEdit(Message message) {
    setState(() {
      _editMessageEventId = message.nostrEventId;
      _editOriginalContent = message.content;
      // Cancel any active reply
      _replyMessageId = null;
      _replyAuthorName = null;
      _replyPreview = null;
    });
  }

  void _cancelEdit() {
    setState(() {
      _editMessageEventId = null;
      _editOriginalContent = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_channel == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final c = ref.watch(infernoColorsProvider);

    // Bottom bar: typing + reply/edit + input — measured so messages get matching bottom padding
    final bottomBar = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Typing indicator
        if (_channel!.nostrGroupId != null)
          Consumer(builder: (context, ref, _) {
            final typingAsync = ref.watch(typingUsersProvider(_channel!.nostrGroupId!));
            return typingAsync.when(
              data: (users) {
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
        // Edit bar (like reply bar, shows what message is being edited)
        if (_editMessageEventId != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: c.gray700,
              border: Border(top: BorderSide(color: c.gray600)),
            ),
            child: Row(
              children: [
                Icon(Icons.edit, size: 16, color: c.accent),
                const SizedBox(width: 8),
                Text('Editing message', style: TextStyle(color: c.accent, fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _editOriginalContent ?? '',
                    style: TextStyle(color: c.gray500, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  onTap: _cancelEdit,
                  child: Icon(Icons.close, size: 16, color: c.gray400),
                ),
              ],
            ),
          ),
        // Input
        MessageInput(
          isActive: widget.isActive,
          onSend: _sendMessage,
          onSendWithMeta: (content, {spoiler = false, fileUrls}) =>
              _sendMessage(content, spoiler: spoiler, fileUrls: fileUrls),
          channelName: _channel!.name,
          editContent: _editOriginalContent,
          onEditCancel: _editMessageEventId != null ? _cancelEdit : null,
          customEmojis: _customEmojis,
          serverId: _channel!.serverId,
          onUploadFiles: (files) async {
            final auth = ref.read(authServiceProvider);
            if (auth.privateKeyHex == null) return [];
            final urls = <String>[];
            for (final file in files) {
              final url = await BlossomClient.uploadFile(
                filePath: file.path,
                privateKeyHex: auth.privateKeyHex!,
                publicKeyHex: auth.publicKeyHex!,
              );
              if (url != null) urls.add(url);
            }
            return urls;
          },
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

    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: MessageList(
                channelId: _channel!.id,
                channel: _channel,
                onReply: _setReply,
                onEdit: _setEdit,
              ),
            ),
            bottomBar,
          ],
        ),
        // NSFW gate overlay — shown once per channel per session
        if (_isNsfwGated)
          Positioned.fill(
            child: Container(
              color: c.gray900,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 48, color: Colors.red.shade300),
                    const SizedBox(height: 12),
                    const Text('NSFW Channel', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('This channel may contain content not suitable\nfor all audiences.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.gray400, fontSize: 14)),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: c.accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () {
                        setState(() => _nsfwAcceptedChannels.add(_channel!.publicId));
                      },
                      child: const Text('I understand, show channel'),
                    ),
                  ],
                ),
              ),
            ),
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
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          if (msg.nostrEventId != null) {
                            Future.delayed(const Duration(milliseconds: 250), () {
                              MessageList.scrollToMessage(msg.nostrEventId!);
                            });
                          }
                        },
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Container(
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
                          ),
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
        cursor: SystemMouseCursors.click,
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
