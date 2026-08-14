import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../models/permission.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/realtime_provider.dart';
import '../providers/server_settings_provider.dart';
import '../providers/conversations_provider.dart';
import '../services/presence_service.dart';
import 'package:go_router/go_router.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import 'context_menu.dart';
import 'user_profile_card.dart';

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
    final c = ref.watch(infernoColorsProvider);

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
                final emoji = m.statusEmoji ?? contactMap[m.pubkey]?.statusEmoji;
                final text = (m.status != null && m.status!.isNotEmpty) ? m.status : contactMap[m.pubkey]?.status;
                if (emoji != null && emoji.isNotEmpty && text != null && text.isNotEmpty) return '$emoji $text';
                if (emoji != null && emoji.isNotEmpty) return emoji;
                return text;
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

              /// Our own custom status, resolved the same way resolveStatus()
              /// does for everyone else.
              String? localUserStatus() {
                final contact = contactMap[auth.publicKeyHex ?? ''];
                final emoji = contact?.statusEmoji;
                final text = contact?.status;
                if (emoji != null && emoji.isNotEmpty && text != null && text.isNotEmpty) {
                  return '$emoji $text';
                }
                if (emoji != null && emoji.isNotEmpty) return emoji;
                return text;
              }

              // Watch roles + role assignments reactively for hoisted groups
              return StreamBuilder<List<Role>>(
                stream: (db.select(db.roles)
                  ..where((r) => r.serverId.equals(widget.serverId))
                  ..orderBy([(r) => OrderingTerm.desc(r.position)])).watch(),
                builder: (context, rolesSnap) {
                  return StreamBuilder<List<RemoteMembershipRole>>(
                    stream: db.select(db.remoteMembershipRoles).watch(),
                    builder: (context, assignSnap) {
                      final allRoles = rolesSnap.data ?? [];
                      final allAssignments = assignSnap.data ?? [];

                      // Build member->roleIds map
                      final memberRoleMap = <int, Set<int>>{};
                      for (final a in allAssignments) {
                        memberRoleMap.putIfAbsent(a.remoteMemberId, () => {}).add(a.roleId);
                      }

                      // Resolve display color: highest-positioned non-gray role color
                      Color? memberRoleColor(RemoteMember m) {
                        final roleIds = memberRoleMap[m.id] ?? {};
                        final memberRoles = allRoles.where((r) => roleIds.contains(r.id)).toList()
                          ..sort((a, b) => (b.position ?? 0).compareTo(a.position ?? 0));
                        for (final r in memberRoles) {
                          if (r.name?.toLowerCase() == 'owner') continue;
                          final color = _parseHexColor(r.color);
                          if (color != null && r.color != '#9E9E9E' && r.color != '#ffffff') return color;
                        }
                        return null;
                      }

                      // Hoisted roles sorted by position desc (excluding Owner)
                      final hoistedRoles = allRoles.where((r) => r.hoist && r.name?.toLowerCase() != 'owner').toList();

                      // Group online members by their highest hoisted role
                      final hoistedMembers = <int, List<RemoteMember>>{}; // roleId -> members
                      final unhoistedOnline = <RemoteMember>[];
                      final placed = <int>{};

                      for (final m in online) {
                        final roleIds = memberRoleMap[m.id] ?? {};
                        // Find highest hoisted role this member has
                        Role? highestHoisted;
                        for (final r in hoistedRoles) {
                          if (roleIds.contains(r.id)) { highestHoisted = r; break; }
                        }
                        if (highestHoisted != null) {
                          hoistedMembers.putIfAbsent(highestHoisted.id, () => []).add(m);
                          placed.add(m.id);
                        } else {
                          unhoistedOnline.add(m);
                        }
                      }

                      return ListView(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                        children: [
                          // Hoisted role sections (by hierarchy position)
                          for (final role in hoistedRoles) ...[
                            if (hoistedMembers.containsKey(role.id) && hoistedMembers[role.id]!.isNotEmpty) ...[
                              _SectionHeader(
                                label: (role.name ?? 'ROLE').toUpperCase(),
                                count: hoistedMembers[role.id]!.length,
                                colors: c,
                                color: _parseHexColor(role.color),
                              ),
                              for (final m in hoistedMembers[role.id]!)
                                _MemberItem(
                                  name: resolveName(m),
                                  avatarUrl: resolveAvatar(m),
                                  pubkey: m.pubkey,
                                  statusColor: _presenceColor(presenceSvc.getPresence(m.pubkey), c),
                                  roleColor: memberRoleColor(m),
                                  statusText: resolveStatus(m),
                                  isOffline: false,
                                  colors: c,
                                  onTap: (pos, size) => showUserProfileCard(context, ref, m.pubkey, anchor: pos, anchorSize: size),
                                  serverId: widget.serverId,
                                ),
                              const SizedBox(height: 8),
                            ],
                          ],
                          // Non-hoisted online members
                          if (unhoistedOnline.isNotEmpty || (!hasLocalUser && auth.publicKeyHex != null)) ...[
                            _SectionHeader(label: 'ONLINE', count: unhoistedOnline.length + (hasLocalUser ? 0 : 1), colors: c),
                            if (!hasLocalUser && auth.publicKeyHex != null)
                              // Read our own presence from the same source as
                              // every other member. These used to be the
                              // literals c.online / 'Online' / false, so the
                              // local user could never appear idle, dnd or
                              // offline here and their custom status never
                              // showed — which is also why this disagreed with
                              // the user panel.
                              _MemberItem(
                                name: localUserName(),
                                avatarUrl: localUserAvatar(),
                                pubkey: auth.publicKeyHex,
                                statusColor: _presenceColor(
                                    presenceSvc.getPresence(auth.publicKeyHex!), c),
                                roleColor: null,
                                statusText: localUserStatus(),
                                isOffline: presenceSvc
                                        .getPresence(auth.publicKeyHex!) ==
                                    OnlineState.offline,
                                colors: c,
                                serverId: widget.serverId,
                              ),
                            for (final m in unhoistedOnline)
                              _MemberItem(
                                name: resolveName(m),
                                avatarUrl: resolveAvatar(m),
                                pubkey: m.pubkey,
                                statusColor: _presenceColor(presenceSvc.getPresence(m.pubkey), c),
                                roleColor: memberRoleColor(m),
                                statusText: resolveStatus(m),
                                isOffline: false,
                                colors: c,
                                onTap: (pos, size) => showUserProfileCard(context, ref, m.pubkey, anchor: pos, anchorSize: size),
                                serverId: widget.serverId,
                              ),
                          ],
                          // Offline
                          if (offline.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            _SectionHeader(label: 'OFFLINE', count: offline.length, colors: c),
                            for (final m in offline)
                              _MemberItem(
                                name: resolveName(m),
                                avatarUrl: resolveAvatar(m),
                                pubkey: m.pubkey,
                                statusColor: c.offline,
                                roleColor: memberRoleColor(m),
                                statusText: null,
                                onTap: (pos, size) => showUserProfileCard(context, ref, m.pubkey, anchor: pos, anchorSize: size),
                                isOffline: true,
                                colors: c,
                                serverId: widget.serverId,
                              ),
                          ],
                        ],
                      );
                    },
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

  static Color? _parseHexColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
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
  final Color? color;

  const _SectionHeader({required this.label, required this.count, required this.colors, this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6, top: 4),
      child: Text(
        '$label \u2014 $count',
        style: TextStyle(
          color: color ?? colors.gray500,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MemberItem extends ConsumerStatefulWidget {
  final String name;
  final String? avatarUrl;
  final String? pubkey;
  final Color statusColor;
  final Color? roleColor;
  final String? statusText;
  final bool isOffline;
  final InfernoColors colors;
  final void Function(Offset position, Size size)? onTap;
  final int serverId;

  const _MemberItem({
    required this.name,
    this.avatarUrl,
    this.pubkey,
    required this.statusColor,
    this.roleColor,
    this.statusText,
    required this.isOffline,
    required this.colors,
    this.onTap,
    required this.serverId,
  });

  @override
  ConsumerState<_MemberItem> createState() => _MemberItemState();
}

class _MemberItemState extends ConsumerState<_MemberItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    return GestureDetector(
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          widget.onTap?.call(box.localToGlobal(Offset.zero), box.size);
        }
      },
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

  void _showMemberContextMenu(BuildContext context, TapDownDetails details, InfernoColors c) async {
    final auth = ref.read(authServiceProvider);
    final pubkey = auth.publicKeyHex;
    if (pubkey == null) return;

    final isSelf = widget.pubkey == pubkey;
    final permSvc = ref.read(permissionServiceProvider);

    // Check permissions
    final canKick = !isSelf && await permSvc.hasPermission(widget.serverId, pubkey, Permission.kickMembers);
    final canBan = !isSelf && await permSvc.hasPermission(widget.serverId, pubkey, Permission.banMembers);
    final canChangeNickname = isSelf
        ? await permSvc.hasPermission(widget.serverId, pubkey, Permission.changeNickname)
        : await permSvc.hasPermission(widget.serverId, pubkey, Permission.manageRoles);

    // Check if target is the server owner (can't moderate the owner)
    bool isTargetOwner = false;
    if (widget.pubkey != null) {
      isTargetOwner = await _isServerOwner(widget.serverId, widget.pubkey!);
    }

    // Don't offer "Add Friend" if we're already friends with this user.
    bool alreadyFriend = false;
    if (!isSelf && widget.pubkey != null) {
      final db = ref.read(databaseProvider);
      final contact = await (db.select(db.contacts)
            ..where((c) => c.pubkey.equals(widget.pubkey!)))
          .getSingleOrNull();
      alreadyFriend = contact?.friendshipStatus == 3;
    }

    if (!mounted) return;

    final timeoutSubmenu = <CtxEntry>[
      CtxItem('60 seconds', null, () => _doTimeout(context, c, const Duration(seconds: 60))),
      CtxItem('5 minutes', null, () => _doTimeout(context, c, const Duration(minutes: 5))),
      CtxItem('10 minutes', null, () => _doTimeout(context, c, const Duration(minutes: 10))),
      CtxItem('1 hour', null, () => _doTimeout(context, c, const Duration(hours: 1))),
      CtxItem('1 day', null, () => _doTimeout(context, c, const Duration(days: 1))),
      CtxItem('1 week', null, () => _doTimeout(context, c, const Duration(days: 7))),
    ];

    showStyledMenu(
      context: context,
      position: details.globalPosition,
      items: [
        CtxItem('Profile', Icons.person_outline, () {
          if (widget.pubkey != null) {
            final box = context.findRenderObject() as RenderBox?;
            if (box != null) {
              final pos = box.localToGlobal(Offset.zero);
              showUserProfileCard(context, ref, widget.pubkey!, anchor: pos, anchorSize: box.size);
            }
          }
        }),
        CtxItem('Mention', Icons.alternate_email, () {}),
        if (!isSelf)
          CtxItem('Message', Icons.message_outlined, () => _openDm(context)),
        if (!isSelf && !alreadyFriend)
          CtxItem('Add Friend', Icons.person_add_alt_1, () => _addFriend(context)),
        if (canChangeNickname)
          CtxItem('Change Nickname', Icons.edit_outlined, () => _showNicknameDialog(context, c)),
        CtxDivider(),
        CtxItem('Copy User ID', Icons.copy, () {
          Clipboard.setData(ClipboardData(text: widget.pubkey ?? widget.name));
        }),
        if (!isSelf && !isTargetOwner && (canKick || canBan)) ...[
          CtxDivider(),
          if (canKick)
            CtxItem('Timeout', Icons.timer_outlined, () {}, submenu: timeoutSubmenu),
          if (canKick)
            CtxItem('Kick', Icons.logout, () => _confirmKick(context, c), danger: true),
          if (canBan)
            CtxItem('Ban', Icons.block, () => _confirmBan(context, c), danger: true),
        ],
      ],
    );
  }

  Future<void> _openDm(BuildContext context) async {
    final pk = widget.pubkey;
    if (pk == null) return;
    final db = ref.read(databaseProvider);
    var conv = await db.contactsDao.getConversationByPubkey(pk);
    if (conv == null) {
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      final contact = await db.contactsDao.getByPubkey(pk);
      await db.contactsDao.insertConversation(ConversationsCompanion.insert(
        publicId: publicId,
        kind: const Value(0),
        counterpartyPubkey: Value(pk),
        counterpartyDisplayName: Value(contact?.displayName ?? contact?.username),
        createdAt: now,
        updatedAt: now,
      ));
      conv = await db.contactsDao.getConversationByPubkey(pk);
    }
    if (conv != null && context.mounted) {
      GoRouter.of(context).go('/conversations/${conv.publicId}');
    }
  }

  Future<void> _addFriend(BuildContext context) async {
    final pk = widget.pubkey;
    if (pk == null) return;
    try {
      await ref.read(contactServiceProvider).addContact(pk);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added ${widget.name} to contacts')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add friend: $e')),
      );
    }
  }

  Future<bool> _isServerOwner(int serverId, String targetPubkey) async {
    final db = ref.read(databaseProvider);
    final server = await (db.select(db.servers)..where((s) => s.id.equals(serverId))).getSingleOrNull();
    if (server == null || server.ownerId == null) return false;
    final owner = await (db.select(db.users)..where((u) => u.id.equals(server.ownerId!))).getSingleOrNull();
    return owner?.nostrPublicKey == targetPubkey;
  }

  void _showNicknameDialog(BuildContext context, InfernoColors c) {
    final controller = TextEditingController(text: widget.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.gray800,
        title: Text('Change Nickname', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Nickname',
            hintStyle: TextStyle(color: c.gray500),
            fillColor: c.gray900,
            filled: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: c.gray400)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: c.accent),
            onPressed: () {
              // TODO: Publish nickname change via Nostr event
              Navigator.of(ctx).pop();
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _doTimeout(BuildContext context, InfernoColors c, Duration duration) {
    if (widget.pubkey == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final memberSvc = ref.read(memberServiceProvider);
    memberSvc.timeoutRemoteMember(
      serverId: widget.serverId,
      targetPubkey: widget.pubkey!,
      duration: duration,
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
    );
  }

  void _confirmKick(BuildContext context, InfernoColors c) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.gray800,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Kick ${widget.name}', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Are you sure you want to kick this member from the server? They can rejoin with an invite.',
                style: TextStyle(color: c.gray400, fontSize: 14)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _doKick();
                    },
                    child: const Text('Kick', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _doKick() {
    if (widget.pubkey == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final memberSvc = ref.read(memberServiceProvider);
    memberSvc.kickRemoteMember(
      serverId: widget.serverId,
      targetPubkey: widget.pubkey!,
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
    );
  }

  void _confirmBan(BuildContext context, InfernoColors c) {
    final reasonController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: c.gray800,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Ban ${widget.name}', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Are you sure you want to ban this member? They will not be able to rejoin.',
                style: TextStyle(color: c.gray400, fontSize: 14)),
              const SizedBox(height: 12),
              TextField(
                controller: reasonController,
                style: TextStyle(color: c.gray200, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Reason (optional)',
                  hintStyle: TextStyle(color: c.gray500),
                  filled: true,
                  fillColor: c.gray900,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.gray700),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: c.gray700),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFED4245)),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _doBan(reasonController.text.trim());
                    },
                    child: const Text('Ban', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _doBan(String reason) {
    if (widget.pubkey == null) return;
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex == null) return;
    final memberSvc = ref.read(memberServiceProvider);
    memberSvc.banRemoteMember(
      serverId: widget.serverId,
      targetPubkey: widget.pubkey!,
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      reason: reason.isNotEmpty ? reason : null,
    );
  }
}
