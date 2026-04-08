import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/database_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/server_settings_provider.dart';
import '../../models/permission.dart';
import '../../theme/theme_provider.dart';
import 'text_channel_screen.dart';
import '../voice/voice_channel_screen.dart';

/// Routes to TextChannelScreen or VoiceChannelScreen based on channel type.
/// Matches Rails: ChannelsController#show renders show.html.erb for text, show_voice.html.erb for voice.
class ChannelTypeRouter extends ConsumerStatefulWidget {
  final String channelPublicId;
  final String serverPublicId;
  final bool isActive;

  const ChannelTypeRouter({
    super.key,
    required this.channelPublicId,
    required this.serverPublicId,
    this.isActive = true,
  });

  @override
  ConsumerState<ChannelTypeRouter> createState() => _ChannelTypeRouterState();
}

class _ChannelTypeRouterState extends ConsumerState<ChannelTypeRouter> {
  int _channelType = 0; // Default to text — avoid null->type transition that causes remount
  String? _lastChannelId;
  bool _canRead = true;
  StreamSubscription? _channelWatchSub;

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

  @override
  void dispose() {
    _channelWatchSub?.cancel();
    super.dispose();
  }

  Future<void> _loadChannelType() async {
    if (widget.channelPublicId == _lastChannelId) return; // Already loaded
    _lastChannelId = widget.channelPublicId;
    final db = ref.read(databaseProvider);
    final ch = await db.serversDao.getChannelByPublicId(widget.channelPublicId);
    if (mounted && ch != null) {
      setState(() => _channelType = ch.channelType);
      _checkReadPermission(ch.serverId);
      _watchChannelDeletion(ch.id);
    }
  }

  /// Watch for this channel being deleted (e.g. by another client via Nostr sync).
  /// Redirects to the server landing page which auto-picks the first remaining channel.
  void _watchChannelDeletion(int channelId) {
    _channelWatchSub?.cancel();
    final db = ref.read(databaseProvider);
    final query = db.select(db.channels)..where((c) => c.id.equals(channelId));
    _channelWatchSub = query.watchSingleOrNull().listen((ch) {
      if (ch == null && mounted) {
        // Channel was deleted — redirect to server landing
        GoRouter.of(context).go('/servers/${widget.serverPublicId}');
      }
    });
  }

  Future<void> _checkReadPermission(int serverId) async {
    final auth = ref.read(authServiceProvider);
    if (auth.publicKeyHex == null) return;
    final can = await ref.read(permissionServiceProvider)
        .hasPermission(serverId, auth.publicKeyHex!, Permission.readMessages);
    if (mounted && can != _canRead) setState(() => _canRead = can);
  }

  @override
  Widget build(BuildContext context) {
    if (!_canRead) {
      final c = ref.watch(infernoColorsProvider);
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.lock_outline, size: 48, color: c.gray500),
          const SizedBox(height: 12),
          Text('You do not have permission to view this channel.',
            style: TextStyle(color: c.gray500, fontSize: 14)),
        ]),
      );
    }

    if (_channelType == 1) {
      return VoiceChannelScreen(
        channelPublicId: widget.channelPublicId,
        serverPublicId: widget.serverPublicId,
      );
    }

    return TextChannelScreen(
      channelPublicId: widget.channelPublicId,
      serverPublicId: widget.serverPublicId,
      isActive: widget.isActive,
    );
  }
}
