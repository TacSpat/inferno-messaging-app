import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../database/database.dart';
import '../../widgets/message_bubble.dart';
import '../../widgets/message_input.dart';

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

  Future<void> _loadConversation() async {
    final db = ref.read(databaseProvider);
    final conv = await (db.select(db.conversations)
          ..where((c) => c.publicId.equals(widget.conversationPublicId)))
        .getSingleOrNull();
    if (mounted) setState(() => _conversation = conv);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
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

    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    if (_conversation == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final name = _conversation!.counterpartyDisplayName
        ?? _conversation!.name
        ?? _conversation!.counterpartyPubkey?.substring(0, 12)
        ?? 'Unknown';

    final messagesAsync = ref.watch(conversationMessagesProvider(_conversation!.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(name),
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                if (messages.isEmpty) {
                  return const Center(
                    child: Text(
                      'No messages yet. Say hello!',
                      style: TextStyle(color: Color(0xFF8899A6)),
                    ),
                  );
                }
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final authService = ref.read(authServiceProvider);
                    final isOwn = message.nostrAuthorPubkey == null ||
                        message.nostrAuthorPubkey == authService.publicKeyHex;
                    return MessageBubble(
                      message: message,
                      isOwn: isOwn,
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
          ),
          MessageInput(onSend: _sendMessage),
        ],
      ),
    );
  }
}
