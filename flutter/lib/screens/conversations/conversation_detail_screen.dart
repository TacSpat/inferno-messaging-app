import 'dart:io';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/realtime_provider.dart';
import '../../providers/unread_provider.dart';
import '../../database/database.dart';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../widgets/typing_indicator.dart';
import '../../services/backfill_service.dart';
import '../../services/blossom_client.dart';
import '../../services/content_safety_service.dart';
import '../../services/dm_service.dart';
import '../../services/group_message_service.dart';

class ConversationDetailScreen extends ConsumerStatefulWidget {
  final String conversationPublicId;
  const ConversationDetailScreen({super.key, required this.conversationPublicId});

  @override
  ConsumerState<ConversationDetailScreen> createState() => _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends ConsumerState<ConversationDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  Conversation? _conversation;

  @override
  void initState() {
    super.initState();
    _loadConversation();
  }

  @override
  void didUpdateWidget(ConversationDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationPublicId != widget.conversationPublicId) {
      _loadConversation();
    }
  }

  Future<void> _loadConversation() async {
    final db = ref.read(databaseProvider);
    final conv = await (db.select(db.conversations)
          ..where((c) => c.publicId.equals(widget.conversationPublicId)))
        .getSingleOrNull();
    if (mounted) setState(() => _conversation = conv);

    // Mark conversation as read and set as active (clear channel active)
    if (conv != null) {
      ref.read(activeConversationIdProvider.notifier).state = conv.id;
      ref.read(activeChannelIdProvider.notifier).state = null;
      await db.messagesDao.markConversationRead(conv.id);
    }

    if (conv?.counterpartyPubkey != null) {
      final shouldBackfill = conv!.lastBackfilledAt == null ||
          DateTime.now().difference(conv.lastBackfilledAt!) > const Duration(minutes: 10);
      if (shouldBackfill) {
        _backfillConversation(conv);
      }
    }
  }

  Future<void> _backfillConversation(Conversation conv) async {
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null || auth.publicKeyHex == null) return;
    if (conv.counterpartyPubkey == null) return;
    try {
      final db = ref.read(databaseProvider);
      final pool = ref.read(relayPoolProvider);
      final groupMsgSvc = GroupMessageService(db, pool);
      final dmSvc = DmService(db, pool);
      final contentSafety = ContentSafetyService(db);
      final backfill = BackfillService(db, pool, groupMsgSvc, dmSvc, contentSafety);
      await backfill.backfillConversation(
        ownPubkey: auth.publicKeyHex!,
        counterpartyPubkey: conv.counterpartyPubkey!,
        backfillDays: 30,
        privateKeyHex: auth.privateKeyHex!,
      );
      // Stamp last backfill time in DB so we don't re-backfill on restart
      await (db.update(db.conversations)..where((c) => c.id.equals(conv.id)))
          .write(ConversationsCompanion(lastBackfilledAt: Value(DateTime.now())));
      // Re-mark as read after backfill (user is viewing)
      await db.messagesDao.markConversationRead(conv.id);
    } catch (_) {}
  }

  @override
  void deactivate() {
    // Update read timestamp on leave and clear active conversation for badge reappearance
    // Must happen in deactivate() — ref is unavailable in dispose()
    if (_conversation != null) {
      final db = ref.read(databaseProvider);
      db.messagesDao.markConversationRead(_conversation!.id);
      final convId = _conversation!.id;
      final activeId = ref.read(activeConversationIdProvider);
      final notifier = ref.read(activeConversationIdProvider.notifier);
      // Defer provider modification to avoid "modified during build" error
      if (activeId == convId) {
        Future(() => notifier.state = null);
      }
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage(String content, {bool spoiler = false, List<String>? fileUrls}) async {
    if (_conversation == null) return;
    final counterpartyPubkey = _conversation!.counterpartyPubkey;
    if (counterpartyPubkey == null) return;

    final authService = ref.read(authServiceProvider);
    final dmService = ref.read(dmServiceProvider);

    if (authService.privateKeyHex == null || authService.publicKeyHex == null) return;

    await dmService.sendDm(
      privateKeyHex: authService.privateKeyHex!,
      publicKeyHex: authService.publicKeyHex!,
      recipientPubkey: counterpartyPubkey,
      content: content,
      fileUrls: fileUrls,
      spoiler: spoiler,
    );
    final err = dmService.lastSendError;
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _sendMessage(content, spoiler: spoiler, fileUrls: fileUrls),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_conversation == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Header lives in MainShell's unified header; this screen only renders
    // the messages / typing / input stack so the two don't duplicate.
    final name = _conversation!.counterpartyDisplayName
        ?? _conversation!.name
        ?? _conversation!.counterpartyPubkey?.substring(0, 12)
        ?? 'Unknown';

    ref.watch(conversationMessagesProvider(_conversation!.id));

    return Column(
      children: [
        // Messages — same layout as server channels
        Expanded(
          child: MessageList(conversationId: _conversation!.id),
        ),
        // Typing indicator
        if (_conversation!.counterpartyPubkey != null)
          Consumer(builder: (context, ref, _) {
            final typingAsync = ref.watch(dmTypingProvider(_conversation!.counterpartyPubkey!));
            return typingAsync.when(
              data: (users) {
                final auth = ref.read(authServiceProvider);
                final others = users.where((u) => u != auth.publicKeyHex).toList();
                return TypingIndicator(typingUsers: others);
              },
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            );
          }),
        // Input with file upload
        MessageInput(
          onSend: _sendMessage,
          onSendWithMeta: (content, {spoiler = false, fileUrls}) =>
              _sendMessage(content, spoiler: spoiler, fileUrls: fileUrls),
          recipientName: name,
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
            if (_conversation?.counterpartyPubkey == null) return;
            final auth = ref.read(authServiceProvider);
            if (auth.privateKeyHex == null) return;
            final typingSvc = ref.read(typingServiceProvider);
            typingSvc.sendDmTyping(
              privateKeyHex: auth.privateKeyHex!,
              publicKeyHex: auth.publicKeyHex!,
              recipientPubkey: _conversation!.counterpartyPubkey!,
            );
          },
        ),
      ],
    );
  }

}
