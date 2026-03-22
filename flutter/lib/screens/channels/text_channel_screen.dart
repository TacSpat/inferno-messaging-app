import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../database/database.dart';
import '../../providers/database_provider.dart';
import '../../providers/servers_provider.dart';
import '../../theme/all_themes.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/message_list.dart';
import '../../widgets/message_input.dart';

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
    }
  }

  Future<void> _loadChannel() async {
    final db = ref.read(databaseProvider);
    final ch = await db.serversDao.getChannelByPublicId(widget.channelPublicId);
    if (mounted) setState(() => _channel = ch);
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
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_channel == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final c = Theme.of(context).extension<InfernoColors>();

    final colors = c!;

    return Column(
      children: [
        // Channel header
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: colors.gray700,
            border: Border(bottom: BorderSide(color: colors.gray900)),
          ),
          child: Row(
            children: [
              Icon(
                _channel!.encrypted ? Icons.lock : Icons.tag,
                size: 20,
                color: colors.gray400,
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
                Container(width: 1, height: 24, color: colors.gray600),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _channel!.topic!,
                    style: TextStyle(color: colors.gray400, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
              // Header action buttons
              _HeaderAction(icon: Icons.push_pin_outlined, tooltip: 'Pinned Messages', colors: colors, onTap: () {}),
              _HeaderAction(icon: Icons.people_outline, tooltip: 'Member List', colors: colors, onTap: () {}),
              const SizedBox(width: 4),
              // Search field
              Container(
                width: 160,
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: colors.gray900,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Expanded(child: Text('Search', style: TextStyle(color: colors.gray500, fontSize: 13))),
                    Icon(Icons.search, size: 16, color: colors.gray500),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Messages
        Expanded(child: MessageList(channelId: _channel!.id)),
        // Input
        MessageInput(onSend: _sendMessage, channelName: _channel!.name),
      ],
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
