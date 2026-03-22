import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';
import '../theme/all_themes.dart';
import '../screens/settings/settings_overlay.dart';

class ChannelSidebar extends ConsumerWidget {
  final Server server;
  final String? activeChannelId;

  const ChannelSidebar({super.key, required this.server, this.activeChannelId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Container(
      width: 240,
      color: c.gray800,
      child: Column(
        children: [
          // Server header
          _ServerHeader(server: server, colors: c),
          // Channel list
          Expanded(
            child: StreamBuilder<List<Channel>>(
              stream: db.serversDao.watchServerChannels(server.id),
              builder: (context, channelSnap) {
                return StreamBuilder<List<Category>>(
                  stream: db.serversDao.watchServerCategories(server.id),
                  builder: (context, catSnap) {
                    final channels = channelSnap.data ?? [];
                    final categories = catSnap.data ?? [];
                    return ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                      children: _buildTree(context, channels, categories, c),
                    );
                  },
                );
              },
            ),
          ),
          // User panel at bottom
          _UserPanel(auth: auth, colors: c),
        ],
      ),
    );
  }

  List<Widget> _buildTree(BuildContext context, List<Channel> channels, List<Category> categories, InfernoColors c) {
    final widgets = <Widget>[];

    final uncategorized = channels.where((ch) => ch.categoryId == null).toList();
    for (final ch in uncategorized) {
      widgets.add(_ChannelItem(channel: ch, serverId: server.publicId, isActive: ch.publicId == activeChannelId, colors: c, afkChannelId: server.afkChannelId));
    }

    for (final cat in categories) {
      widgets.add(_CategoryHeader(name: cat.name ?? '', colors: c));
      final catChannels = channels.where((ch) => ch.categoryId == cat.id).toList();
      for (final ch in catChannels) {
        widgets.add(_ChannelItem(channel: ch, serverId: server.publicId, isActive: ch.publicId == activeChannelId, colors: c, afkChannelId: server.afkChannelId));
      }
    }

    if (widgets.isEmpty) {
      widgets.add(Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No channels', style: TextStyle(color: c.gray500, fontSize: 13)),
      ));
    }

    return widgets;
  }
}

class _ServerHeader extends StatelessWidget {
  final Server server;
  final InfernoColors colors;
  const _ServerHeader({required this.server, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.gray900)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              server.name,
              style: TextStyle(color: colors.gray50, fontWeight: FontWeight.w600, fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(Icons.keyboard_arrow_down, color: colors.gray400, size: 20),
        ],
      ),
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  final String name;
  final InfernoColors colors;
  const _CategoryHeader({required this.name, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4, left: 4, right: 4),
      child: Row(
        children: [
          Icon(Icons.keyboard_arrow_down, color: colors.gray500, size: 12),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              name.toUpperCase(),
              style: TextStyle(color: colors.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelItem extends StatefulWidget {
  final Channel channel;
  final String serverId;
  final bool isActive;
  final InfernoColors colors;
  final int? afkChannelId;
  const _ChannelItem({required this.channel, required this.serverId, required this.isActive, required this.colors, this.afkChannelId});

  @override
  State<_ChannelItem> createState() => _ChannelItemState();
}

class _ChannelItemState extends State<_ChannelItem> {
  bool _hovering = false;

  IconData _channelIcon() {
    final ch = widget.channel;
    final isVoice = ch.channelType == 1;
    final isNested = ch.parentChannelId != null;
    final isAfk = widget.afkChannelId != null && ch.id == widget.afkChannelId;

    if (isAfk) return Icons.nightlight_round;
    if (isNested && isVoice) return Icons.phone;
    if (isVoice) return Icons.cell_tower;
    if (ch.encrypted) return Icons.lock;
    return Icons.tag;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final active = widget.isActive;
    final isNested = widget.channel.parentChannelId != null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => context.go('/servers/${widget.serverId}/channels/${widget.channel.publicId}'),
        child: Container(
          margin: EdgeInsets.only(left: isNested ? 12 : 0, top: 1, bottom: 1),
          decoration: BoxDecoration(
            color: active ? c.gray600 : (_hovering ? c.gray700 : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              // Red accent bar for active channel
              Container(
                width: 3,
                height: 28,
                decoration: BoxDecoration(
                  color: active ? c.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(width: active ? 5 : 8),
              Icon(
                _channelIcon(),
                size: 18,
                color: active ? c.gray200 : c.gray500,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.channel.name,
                  style: TextStyle(
                    color: active ? Colors.white : (_hovering ? c.gray200 : c.gray500),
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserPanel extends StatelessWidget {
  final AuthService auth;
  final InfernoColors colors;
  const _UserPanel({required this.auth, required this.colors});

  @override
  Widget build(BuildContext context) {
    final pubkey = auth.publicKeyHex;
    final shortName = pubkey != null ? '${pubkey.substring(0, 8)}...' : 'User';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: colors.gray950,
        border: Border(top: BorderSide(color: colors.gray900)),
      ),
      child: Row(
        children: [
          // Avatar with status dot
          Stack(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: colors.gray600,
                child: Text(shortName[0].toUpperCase(), style: TextStyle(color: colors.gray200, fontSize: 14)),
              ),
              Positioned(
                right: -1, bottom: -1,
                child: Container(
                  width: 14, height: 14,
                  decoration: BoxDecoration(
                    color: colors.online,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.gray950, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        shortName,
                        style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'v0.2.0',
                      style: TextStyle(color: colors.gray500, fontSize: 10),
                    ),
                  ],
                ),
                Text(
                  'Online',
                  style: TextStyle(color: colors.gray500, fontSize: 11),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => showSettingsOverlay(context),
            child: Icon(Icons.settings, color: colors.gray400, size: 18),
          ),
        ],
      ),
    );
  }
}
