import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/all_themes.dart';

class MemberList extends ConsumerWidget {
  final int serverId;

  const MemberList({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Container(
      width: 240,
      color: c.gray800,
      child: StreamBuilder<List<RemoteMember>>(
        stream: db.serversDao.watchRemoteMembers(serverId),
        builder: (context, snapshot) {
          final members = snapshot.data ?? [];

          // Separate online vs offline (onlineState: 0=offline, 1=online, 2=idle, 3=dnd)
          final online = members.where((m) => m.onlineState > 0).toList();
          final offline = members.where((m) => m.onlineState == 0).toList();

          // If no remote members at all, show at least the local user
          final hasLocalUser = auth.publicKeyHex != null &&
              members.any((m) => m.pubkey == auth.publicKeyHex);

          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            children: [
              // ONLINE section
              _SectionHeader(
                label: 'ONLINE',
                count: online.length + (hasLocalUser ? 0 : 1),
                colors: c,
              ),
              // Show local user first if not already in remote members
              if (!hasLocalUser && auth.publicKeyHex != null)
                _MemberItem(
                  name: _localUserName(auth),
                  avatarUrl: null,
                  statusColor: c.online,
                  roleColor: null,
                  statusText: 'Online',
                  isOffline: false,
                  colors: c,
                ),
              for (final m in online)
                _MemberItem(
                  name: m.displayName ?? m.username ?? '${m.pubkey.substring(0, 8)}...',
                  avatarUrl: m.avatarUrl,
                  statusColor: _statusColor(m.onlineState, c),
                  roleColor: null,
                  statusText: m.status,
                  isOffline: false,
                  colors: c,
                ),
              if (offline.isNotEmpty) ...[
                const SizedBox(height: 8),
                _SectionHeader(
                  label: 'OFFLINE',
                  count: offline.length,
                  colors: c,
                ),
                for (final m in offline)
                  _MemberItem(
                    name: m.displayName ?? m.username ?? '${m.pubkey.substring(0, 8)}...',
                    avatarUrl: m.avatarUrl,
                    statusColor: c.offline,
                    roleColor: null,
                    statusText: m.status,
                    isOffline: true,
                    colors: c,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  String _localUserName(dynamic auth) {
    final pubkey = auth.publicKeyHex as String?;
    if (pubkey == null) return 'User';
    return '${pubkey.substring(0, 8)}...';
  }

  Color _statusColor(int state, InfernoColors c) {
    switch (state) {
      case 1: return c.online;
      case 2: return c.idle;
      case 3: return c.dnd;
      default: return c.offline;
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final InfernoColors colors;

  const _SectionHeader({required this.label, required this.count, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6, top: 4),
      child: Text(
        '$label \u2014 $count',
        style: TextStyle(
          color: colors.gray500,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MemberItem extends StatefulWidget {
  final String name;
  final String? avatarUrl;
  final Color statusColor;
  final Color? roleColor;
  final String? statusText;
  final bool isOffline;
  final InfernoColors colors;

  const _MemberItem({
    required this.name,
    this.avatarUrl,
    required this.statusColor,
    this.roleColor,
    this.statusText,
    required this.isOffline,
    required this.colors,
  });

  @override
  State<_MemberItem> createState() => _MemberItemState();
}

class _MemberItemState extends State<_MemberItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    return GestureDetector(
      onSecondaryTapDown: (details) => _showMemberContextMenu(context, details, c),
      child: MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: _hovering ? c.gray700 : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Opacity(
          opacity: widget.isOffline ? 0.4 : 1.0,
          child: Row(
            children: [
              // Avatar with status dot
              Stack(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: c.gray600,
                    backgroundImage: widget.avatarUrl != null ? NetworkImage(widget.avatarUrl!) : null,
                    child: widget.avatarUrl == null
                        ? Text(widget.name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 13))
                        : null,
                  ),
                  Positioned(
                    right: -1, bottom: -1,
                    child: Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        color: widget.statusColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.gray800, width: 2),
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
                    Text(
                      widget.name,
                      style: TextStyle(
                        color: widget.roleColor ?? c.gray200,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.statusText != null && widget.statusText!.isNotEmpty)
                      Text(
                        widget.statusText!,
                        style: TextStyle(color: c.gray500, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  void _showMemberContextMenu(BuildContext context, TapDownDetails details, InfernoColors c) {
    final pos = details.globalPosition;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      color: c.gray900,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: c.gray700),
      ),
      items: [
        PopupMenuItem(value: 'profile', child: Row(children: [
          Icon(Icons.person_outline, size: 16, color: c.gray400),
          const SizedBox(width: 10),
          Text('Profile', style: TextStyle(color: c.gray200, fontSize: 14)),
        ])),
        PopupMenuItem(value: 'mention', child: Row(children: [
          Icon(Icons.alternate_email, size: 16, color: c.gray400),
          const SizedBox(width: 10),
          Text('Mention', style: TextStyle(color: c.gray200, fontSize: 14)),
        ])),
        PopupMenuItem(value: 'message', child: Row(children: [
          Icon(Icons.message_outlined, size: 16, color: c.gray400),
          const SizedBox(width: 10),
          Text('Message', style: TextStyle(color: c.gray200, fontSize: 14)),
        ])),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'add_friend', child: Row(children: [
          Icon(Icons.person_add_outlined, size: 16, color: c.gray400),
          const SizedBox(width: 10),
          Text('Add Friend', style: TextStyle(color: c.gray200, fontSize: 14)),
        ])),
        PopupMenuItem(value: 'roles', child: Row(children: [
          Icon(Icons.shield_outlined, size: 16, color: c.gray400),
          const SizedBox(width: 10),
          Text('Roles', style: TextStyle(color: c.gray200, fontSize: 14)),
        ])),
        PopupMenuItem(value: 'nickname', child: Row(children: [
          Icon(Icons.edit_outlined, size: 16, color: c.gray400),
          const SizedBox(width: 10),
          Text('Change Nickname', style: TextStyle(color: c.gray200, fontSize: 14)),
        ])),
        const PopupMenuDivider(),
        PopupMenuItem(value: 'kick', child: Row(children: [
          Icon(Icons.logout, size: 16, color: c.accent),
          const SizedBox(width: 10),
          Text('Kick', style: TextStyle(color: c.accent, fontSize: 14)),
        ])),
        PopupMenuItem(value: 'ban', child: Row(children: [
          Icon(Icons.block, size: 16, color: c.accent),
          const SizedBox(width: 10),
          Text('Ban', style: TextStyle(color: c.accent, fontSize: 14)),
        ])),
      ],
    );
  }
}
