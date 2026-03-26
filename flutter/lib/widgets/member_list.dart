import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/realtime_provider.dart';
import '../providers/server_settings_provider.dart';
import '../services/presence_service.dart';
import '../theme/all_themes.dart';

/// Validate URL is a real HTTP URL, not a Rails-local relative path
String? _validUrl(String? url) {
  if (url != null && url.startsWith('http')) return url;
  return null;
}

class MemberList extends ConsumerStatefulWidget {
  final int serverId;

  const MemberList({super.key, required this.serverId});

  @override
  ConsumerState<MemberList> createState() => _MemberListState();
}

class _MemberListState extends ConsumerState<MemberList> {
  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    // Watch presence updates to trigger rebuilds when any user's state changes
    ref.watch(presenceUpdatesProvider);

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: c.gray800,
        border: Border(
          left: BorderSide(color: c.accent.withValues(alpha: 0.10), width: 1),
        ),
      ),
      child: StreamBuilder<List<RemoteMember>>(
        stream: db.serversDao.watchRemoteMembers(widget.serverId),
        builder: (context, snapshot) {
          final members = snapshot.data ?? [];

          // Also watch contacts for profile fallback
          return StreamBuilder<List<Contact>>(
            stream: db.select(db.contacts).watch(),
            builder: (context, contactSnap) {
              final contacts = contactSnap.data ?? [];
              final contactMap = <String, Contact>{};
              for (final c in contacts) {
                contactMap[c.pubkey] = c;
              }

              // Resolve names: prefer remote_member fields, fallback to contacts
              String resolveName(RemoteMember m) {
                if (m.displayName != null && m.displayName!.isNotEmpty) return m.displayName!;
                if (m.username != null && m.username!.isNotEmpty) return m.username!;
                final contact = contactMap[m.pubkey];
                if (contact != null) {
                  if (contact.displayName != null && contact.displayName!.isNotEmpty) return contact.displayName!;
                  if (contact.username != null && contact.username!.isNotEmpty) return contact.username!;
                }
                return '${m.pubkey.substring(0, 8)}...';
              }

              String? resolveAvatar(RemoteMember m) {
                final url = m.avatarUrl ?? contactMap[m.pubkey]?.avatarUrl;
                // Only return valid HTTP URLs — filter out Rails-local relative paths
                if (url != null && url.startsWith('http')) return url;
                return null;
              }

              String? resolveStatus(RemoteMember m) {
                if (m.status != null && m.status!.isNotEmpty) return m.status;
                return contactMap[m.pubkey]?.status;
              }

              final presenceSvc = ref.watch(presenceServiceProvider);

              // Use presence service for online state (more accurate than DB)
              final online = members.where((m) {
                final state = presenceSvc.getPresence(m.pubkey);
                return state != OnlineState.offline;
              }).toList();
              final offline = members.where((m) {
                final state = presenceSvc.getPresence(m.pubkey);
                return state == OnlineState.offline;
              }).toList();

              final hasLocalUser = auth.publicKeyHex != null &&
                  members.any((m) => m.pubkey == auth.publicKeyHex);

              String localUserName() {
                if (auth.publicKeyHex == null) return 'User';
                final contact = contactMap[auth.publicKeyHex!];
                if (contact?.displayName != null && contact!.displayName!.isNotEmpty) return contact.displayName!;
                if (contact?.username != null && contact!.username!.isNotEmpty) return contact.username!;
                return '${auth.publicKeyHex!.substring(0, 8)}...';
              }

              String? localUserAvatar() {
                if (auth.publicKeyHex == null) return null;
                return contactMap[auth.publicKeyHex!]?.avatarUrl;
              }

              // Resolve role colors using PermissionService (matches Rails display_color)
              return FutureBuilder<Map<int, Color?>>(
                future: _resolveDisplayColors(members),
                builder: (context, roleSnap) {
                  final colorMap = roleSnap.data ?? {};

                  Color? memberRoleColor(RemoteMember m) => colorMap[m.id];

                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    children: [
                      _SectionHeader(label: 'ONLINE', count: online.length + (hasLocalUser ? 0 : 1), colors: c),
                      if (!hasLocalUser && auth.publicKeyHex != null)
                        _MemberItem(
                          name: localUserName(),
                          avatarUrl: localUserAvatar(),
                          statusColor: c.online,
                          roleColor: null,
                          statusText: 'Online',
                          isOffline: false,
                          colors: c,
                        ),
                      for (final m in online)
                        _MemberItem(
                          name: resolveName(m),
                          avatarUrl: resolveAvatar(m),
                          statusColor: _presenceColor(presenceSvc.getPresence(m.pubkey), c),
                          roleColor: memberRoleColor(m),
                          statusText: resolveStatus(m),
                          isOffline: false,
                          colors: c,
                        ),
                      if (offline.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _SectionHeader(label: 'OFFLINE', count: offline.length, colors: c),
                        for (final m in offline)
                          _MemberItem(
                            name: resolveName(m),
                            avatarUrl: resolveAvatar(m),
                            statusColor: c.offline,
                            roleColor: memberRoleColor(m),
                            statusText: null, // no status for offline members
                            isOffline: true,
                            colors: c,
                          ),
                      ],
                    ],
                  );
                },
              );
            },
          );
        },
      ),
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

  /// Resolve display color for each member — matches Rails: skip owner role, first non-gray color
  Future<Map<int, Color?>> _resolveDisplayColors(List<RemoteMember> members) async {
    final permSvc = ref.read(permissionServiceProvider);
    final result = <int, Color?>{};
    for (final m in members) {
      final colorHex = await permSvc.getDisplayColor(widget.serverId, m.pubkey);
      result[m.id] = colorHex != '#ffffff' ? _parseHexColor(colorHex) : null;
    }
    return result;
  }

  static Color? _parseHexColor(String hex) {
    try {
      final cleaned = hex.replaceFirst('#', '');
      if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {}
    return null;
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
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          gradient: _hovering ? LinearGradient(
            colors: [c.accent.withValues(alpha: 0.1), c.accent.withValues(alpha: 0.02)],
            begin: Alignment.centerLeft, end: Alignment.centerRight,
          ) : null,
          border: _hovering ? Border(left: BorderSide(color: c.accent.withValues(alpha: 0.5), width: 2)) : null,
          borderRadius: _hovering ? null : BorderRadius.circular(4),
          boxShadow: _hovering ? [
            BoxShadow(color: c.accent.withValues(alpha: 0.1), blurRadius: 8, offset: const Offset(4, 0)),
          ] : null,
        ),
        child: Opacity(
          opacity: widget.isOffline ? 0.4 : 1.0,
          child: Row(
            children: [
              // Avatar with status dot + hover glow
              Stack(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: _hovering && !widget.isOffline ? [
                        BoxShadow(color: c.accent.withValues(alpha: 0.35), blurRadius: 8),
                      ] : null,
                    ),
                    child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.transparent,
                    backgroundImage: _validUrl(widget.avatarUrl) != null ? NetworkImage(_validUrl(widget.avatarUrl)!) : null,
                    child: _validUrl(widget.avatarUrl) == null
                        ? Text(widget.name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 13))
                        : null,
                  )),
                  Positioned(
                    right: -1, bottom: -1,
                    child: Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        color: widget.statusColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.gray800, width: 2),
                        boxShadow: !widget.isOffline ? [
                          BoxShadow(color: widget.statusColor.withValues(alpha: 0.5), blurRadius: 5, spreadRadius: 1),
                        ] : null,
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
      color: c.gray800,
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
