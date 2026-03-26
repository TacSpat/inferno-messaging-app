import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/realtime_provider.dart';
import '../../database/database.dart';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';
import '../../widgets/typing_indicator.dart';
import '../../services/backfill_service.dart';
import '../../services/blossom_client.dart';
import '../../services/dm_service.dart';
import '../../services/group_message_service.dart';
import '../../services/presence_service.dart';
import '../../theme/all_themes.dart';

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

    if (conv?.counterpartyPubkey != null) {
      _backfillConversation(conv!);
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
      final backfill = BackfillService(db, pool, groupMsgSvc, dmSvc);
      await backfill.backfillConversation(
        ownPubkey: auth.publicKeyHex!,
        counterpartyPubkey: conv.counterpartyPubkey!,
        backfillDays: 30,
        privateKeyHex: auth.privateKeyHex!,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage(String content) async {
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
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_conversation == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final c = Theme.of(context).extension<InfernoColors>()!;
    final presenceSvc = ref.watch(presenceServiceProvider);
    ref.watch(presenceUpdatesProvider); // Trigger rebuild on presence changes

    final name = _conversation!.counterpartyDisplayName
        ?? _conversation!.name
        ?? _conversation!.counterpartyPubkey?.substring(0, 12)
        ?? 'Unknown';

    final presence = _conversation!.counterpartyPubkey != null
        ? presenceSvc.getPresence(_conversation!.counterpartyPubkey!)
        : OnlineState.offline;

    final messagesAsync = ref.watch(conversationMessagesProvider(_conversation!.id));

    return Column(
      children: [
        // DM header (matches Rails conversation header style)
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: c.gray700,
            border: Border(bottom: BorderSide(color: c.gray900)),
          ),
          child: Row(
            children: [
              Icon(Icons.alternate_email, size: 20, color: c.gray400),
              const SizedBox(width: 8),
              Text(name, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
              const SizedBox(width: 8),
              // Presence dot
              Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  color: _presenceColor(presence, c),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(presence.value[0].toUpperCase() + presence.value.substring(1),
                style: TextStyle(color: c.gray500, fontSize: 12)),
              const Spacer(),
              // Pin button placeholder
              _HeaderAction(icon: Icons.push_pin_outlined, tooltip: 'Pinned Messages', colors: c, onTap: () {}),
            ],
          ),
        ),
        // Messages — same layout as server channels
        Expanded(
          child: MessageList(conversationId: _conversation!.id),
        ),
        // Typing indicator
        if (_conversation!.counterpartyPubkey != null)
          Consumer(builder: (context, ref, _) {
            final typingAsync = ref.watch(typingUsersProvider(_conversation!.counterpartyPubkey!));
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
            typingSvc.sendTyping(
              privateKeyHex: auth.privateKeyHex!,
              publicKeyHex: auth.publicKeyHex!,
              channelGroupId: _conversation!.counterpartyPubkey!,
            );
          },
        ),
      ],
    );
  }

  static Color _presenceColor(OnlineState state, InfernoColors c) {
    switch (state) {
      case OnlineState.online: return c.online;
      case OnlineState.idle: return c.idle;
      case OnlineState.dnd: return c.dnd;
      default: return c.offline;
    }
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
