import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/database_provider.dart';
import '../../database/database.dart';
import 'text_channel_screen.dart';
import '../voice/voice_channel_screen.dart';

/// Routes to TextChannelScreen or VoiceChannelScreen based on channel type.
/// Matches Rails: ChannelsController#show renders show.html.erb for text, show_voice.html.erb for voice.
class ChannelTypeRouter extends ConsumerStatefulWidget {
  final String channelPublicId;
  final String serverPublicId;

  const ChannelTypeRouter({
    super.key,
    required this.channelPublicId,
    required this.serverPublicId,
  });

  @override
  ConsumerState<ChannelTypeRouter> createState() => _ChannelTypeRouterState();
}

class _ChannelTypeRouterState extends ConsumerState<ChannelTypeRouter> {
  int _channelType = 0; // Default to text — avoid null->type transition that causes remount
  String? _lastChannelId;

  @override
  void initState() {
    super.initState();
    _loadChannelType();
  }

  @override
  void didUpdateWidget(ChannelTypeRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelPublicId != widget.channelPublicId) {
      _loadChannelType();
    }
    // Don't reload on parent rebuild if channelId hasn't changed
  }

  Future<void> _loadChannelType() async {
    if (widget.channelPublicId == _lastChannelId) return; // Already loaded
    _lastChannelId = widget.channelPublicId;
    final db = ref.read(databaseProvider);
    final ch = await db.serversDao.getChannelByPublicId(widget.channelPublicId);
    if (mounted && ch != null) setState(() => _channelType = ch.channelType);
  }

  @override
  Widget build(BuildContext context) {
    if (_channelType == 1) {
      return VoiceChannelScreen(
        key: ValueKey('voice-${widget.channelPublicId}'),
        channelPublicId: widget.channelPublicId,
        serverPublicId: widget.serverPublicId,
      );
    }

    return TextChannelScreen(
      key: ValueKey('text-${widget.channelPublicId}'),
      channelPublicId: widget.channelPublicId,
      serverPublicId: widget.serverPublicId,
    );
  }
}
