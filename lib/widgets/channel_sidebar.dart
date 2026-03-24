import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/servers_provider.dart';
import '../services/auth_service.dart';
import '../services/presence_service.dart';
import '../providers/realtime_provider.dart';
import '../theme/all_themes.dart';
import '../screens/settings/settings_overlay.dart';
import 'channel_reorder.dart';

class ChannelSidebar extends ConsumerStatefulWidget {
  final Server server;
  final String? activeChannelId;

  const ChannelSidebar({super.key, required this.server, this.activeChannelId});

  @override
  ConsumerState<ChannelSidebar> createState() => _ChannelSidebarState();
}

class _ChannelSidebarState extends ConsumerState<ChannelSidebar> {
  final Set<String> _collapsedCategories = {};

  @override
  Widget build(BuildContext context) {
    final db = ref.watch(databaseProvider);
    final auth = ref.watch(authServiceProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Container(
      width: 240,
      color: c.gray800,
      child: Column(
        children: [
          _ServerHeader(server: widget.server, colors: c),
          Expanded(
            child: StreamBuilder<List<Channel>>(
              stream: db.serversDao.watchServerChannels(widget.server.id),
              builder: (context, channelSnap) {
                return StreamBuilder<List<Category>>(
                  stream: db.serversDao.watchServerCategories(widget.server.id),
                  builder: (context, catSnap) {
                    final channels = channelSnap.data ?? [];
                    final categories = catSnap.data ?? [];
                    if (channels.isEmpty && categories.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('No channels', style: TextStyle(color: c.gray500, fontSize: 13)),
                      );
                    }
                    return ChannelReorderList(
                      server: widget.server,
                      activeChannelId: widget.activeChannelId,
                      channels: channels,
                      categories: categories,
                      colors: c,
                      collapsedCategories: _collapsedCategories,
                      onToggleCategory: (catId) {
                        setState(() {
                          if (_collapsedCategories.contains(catId)) {
                            _collapsedCategories.remove(catId);
                          } else {
                            _collapsedCategories.add(catId);
                          }
                        });
                      },
                    );
                  },
                );
              },
            ),
          ),
          _UserPanel(auth: auth, colors: c),
        ],
      ),
    );
  }

}

class _ServerHeader extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _ServerHeader({required this.server, required this.colors});

  @override
  ConsumerState<_ServerHeader> createState() => _ServerHeaderState();
}

class _ServerHeaderState extends ConsumerState<_ServerHeader> {
  bool _hovering = false;
  bool _dropdownOpen = false;

  void _toggleDropdown() {
    if (_dropdownOpen) return;
    setState(() => _dropdownOpen = true);

    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final c = widget.colors;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _ServerDropdownOverlay(
        server: widget.server,
        colors: c,
        anchor: Rect.fromLTWH(offset.dx, offset.dy + renderBox.size.height, renderBox.size.width, 0),
        onDismiss: () {
          entry.remove();
          if (mounted) setState(() => _dropdownOpen = false);
        },
        ref: ref,
        router: GoRouter.of(this.context),
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: _toggleDropdown,
        child: Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: _hovering || _dropdownOpen ? c.gray700 : Colors.transparent,
            border: Border(bottom: BorderSide(color: c.gray900)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.server.name,
                  style: TextStyle(color: c.gray50, fontWeight: FontWeight.w600, fontSize: 15),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.keyboard_arrow_down, color: c.gray400, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerDropdownOverlay extends StatefulWidget {
  final Server server;
  final InfernoColors colors;
  final Rect anchor;
  final VoidCallback onDismiss;
  final WidgetRef ref;
  final GoRouter router;

  const _ServerDropdownOverlay({
    required this.server,
    required this.colors,
    required this.anchor,
    required this.onDismiss,
    required this.ref,
    required this.router,
  });

  @override
  State<_ServerDropdownOverlay> createState() => _ServerDropdownOverlayState();
}

class _ServerDropdownOverlayState extends State<_ServerDropdownOverlay> {
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;

    return Stack(
      children: [
        // Dismiss layer
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onDismiss,
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.transparent),
          ),
        ),
        // Dropdown menu
        Positioned(
          left: widget.anchor.left + 8,
          top: widget.anchor.top + 4,
          width: widget.anchor.width - 16,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.gray900,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.gray700),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))],
              ),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _DropdownItem(
                    icon: Icons.link,
                    label: 'Invite People',
                    colors: c,
                    onTap: () {
                      widget.onDismiss();
                      _showInviteDialog(context);
                    },
                  ),
                  _DropdownItem(
                    icon: Icons.settings,
                    label: 'Server Settings',
                    colors: c,
                    onTap: () {
                      widget.onDismiss();
                      _showServerSettings(context);
                    },
                  ),
                  _DropdownItem(
                    icon: Icons.add,
                    label: 'Create Channel',
                    colors: c,
                    onTap: () {
                      widget.onDismiss();
                      _showCreateChannel(context);
                    },
                  ),
                  _DropdownItem(
                    icon: Icons.create_new_folder_outlined,
                    label: 'Create Category',
                    colors: c,
                    onTap: () {
                      widget.onDismiss();
                      _showCreateCategory(context);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Container(height: 1, color: c.gray700),
                  ),
                  _DropdownItem(
                    icon: null,
                    label: 'Leave Server',
                    colors: c,
                    danger: true,
                    onTap: () {
                      widget.onDismiss();
                      _leaveServer(context);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _showServerSettings(BuildContext context) {
    // TODO: open server settings overlay
  }

  Future<void> _showInviteDialog(BuildContext ctx) async {
    final c = widget.colors;
    final auth = widget.ref.read(authServiceProvider);
    final inviteService = widget.ref.read(inviteServiceProvider);

    if (auth.privateKeyHex == null) return;

    // Create invite
    String? inviteCode;
    String? error;
    try {
      final invite = await inviteService.createInvite(
        privateKeyHex: auth.privateKeyHex!,
        publicKeyHex: auth.publicKeyHex!,
        server: widget.server,
        creatorId: 1,
      );
      inviteCode = invite.code;
    } catch (e) {
      error = e.toString();
    }

    if (!ctx.mounted) return;

    showDialog(
      context: ctx,
      builder: (context) => Dialog(
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
              Text('Invite People', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Share this invite link with others:', style: TextStyle(color: c.gray400, fontSize: 14)),
              const SizedBox(height: 12),
              if (error != null)
                Text(error, style: TextStyle(color: c.accent, fontSize: 13))
              else if (inviteCode != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          'inferno://invite/${widget.server.nostrGroupId ?? widget.server.publicId}/$inviteCode',
                          style: TextStyle(color: c.gray200, fontSize: 13, fontFamily: 'monospace'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(
                            text: 'inferno://invite/${widget.server.nostrGroupId ?? widget.server.publicId}/$inviteCode',
                          ));
                        },
                        child: Icon(Icons.copy, size: 16, color: c.gray400),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Done', style: TextStyle(color: c.gray400)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCreateChannel(BuildContext ctx) async {
    final c = widget.colors;
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: ctx,
      builder: (context) => Dialog(
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
              Text('Create Channel', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'channel-name',
                  hintStyle: TextStyle(color: c.gray500),
                  fillColor: c.gray900,
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel', style: TextStyle(color: c.gray400)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, nameController.text.trim()),
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (result != null && result.isNotEmpty) {
      final db = widget.ref.read(databaseProvider);
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      final nostrGroupId = widget.server.nostrGroupId != null ? '${widget.server.nostrGroupId}-$publicId' : null;

      // Get current max position
      final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(widget.server.id))).get();
      final maxPos = channels.fold<int>(0, (max, ch) => (ch.position ?? 0) > max ? (ch.position ?? 0) : max);

      await db.into(db.channels).insert(ChannelsCompanion.insert(
        publicId: publicId,
        serverId: widget.server.id,
        name: result.toLowerCase().replaceAll(' ', '-'),
        channelType: 0,
        position: Value(maxPos + 1),
        nostrGroupId: Value(nostrGroupId),
        createdAt: now,
        updatedAt: now,
      ));

      // Publish structure update to relays
      final auth = widget.ref.read(authServiceProvider);
      final serverPublish = widget.ref.read(serverPublishServiceProvider);
      if (auth.privateKeyHex != null) {
        await serverPublish.publishStructure(
          privateKeyHex: auth.privateKeyHex!,
          publicKeyHex: auth.publicKeyHex!,
          server: widget.server,
        );
      }
    }
    nameController.dispose();
  }

  Future<void> _showCreateCategory(BuildContext ctx) async {
    final c = widget.colors;
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: ctx,
      builder: (context) => Dialog(
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
              Text('Create Category', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                style: TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Category name',
                  hintStyle: TextStyle(color: c.gray500),
                  fillColor: c.gray900,
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel', style: TextStyle(color: c.gray400)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context, nameController.text.trim()),
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (result != null && result.isNotEmpty) {
      final db = widget.ref.read(databaseProvider);
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);

      final cats = await (db.select(db.categories)..where((cat) => cat.serverId.equals(widget.server.id))).get();
      final maxPos = cats.fold<int>(0, (max, cat) => (cat.position ?? 0) > max ? (cat.position ?? 0) : max);

      await db.into(db.categories).insert(CategoriesCompanion.insert(
        publicId: publicId,
        serverId: widget.server.id,
        name: Value(result),
        position: Value(maxPos + 1),
        createdAt: now,
        updatedAt: now,
      ));
    }
    nameController.dispose();
  }

  Future<void> _leaveServer(BuildContext ctx) async {
    final c = widget.colors;
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (context) => Dialog(
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
              Text('Leave Server', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('Are you sure you want to leave "${widget.server.name}"? You won\'t be able to rejoin unless you are re-invited.',
                style: TextStyle(color: c.gray400, fontSize: 14)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text('Cancel', style: TextStyle(color: c.gray400)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Leave Server', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true) {
      final db = widget.ref.read(databaseProvider);
      final serverId = widget.server.id;
      // Full delete: messages, membership, channels, categories, members, server
      final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(serverId))).get();
      for (final ch in channels) {
        await (db.delete(db.messages)..where((m) => m.channelId.equals(ch.id))).go();
      }
      await (db.delete(db.serverMemberships)..where((m) => m.serverId.equals(serverId))).go();
      await (db.delete(db.channels)..where((ch) => ch.serverId.equals(serverId))).go();
      await (db.delete(db.categories)..where((cat) => cat.serverId.equals(serverId))).go();
      await (db.delete(db.remoteMembers)..where((m) => m.serverId.equals(serverId))).go();
      await (db.delete(db.servers)..where((s) => s.id.equals(serverId))).go();
      // Navigate
      widget.router.go('/conversations');
    }
  }
}

class _DropdownItem extends StatefulWidget {
  final IconData? icon;
  final String label;
  final InfernoColors colors;
  final bool danger;
  final VoidCallback onTap;

  const _DropdownItem({
    this.icon,
    required this.label,
    required this.colors,
    this.danger = false,
    required this.onTap,
  });

  @override
  State<_DropdownItem> createState() => _DropdownItemState();
}

class _DropdownItemState extends State<_DropdownItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final textColor = widget.danger
        ? c.accent
        : (_hovering ? Colors.white : c.gray400);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: _hovering ? c.gray700 : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 18, color: textColor),
                const SizedBox(width: 10),
              ],
              Text(
                widget.label,
                style: TextStyle(color: textColor, fontSize: 14, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserPanel extends ConsumerWidget {
  final AuthService auth;
  final InfernoColors colors;
  const _UserPanel({required this.auth, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pubkey = auth.publicKeyHex;
    final db = ref.watch(databaseProvider);
    final presenceSvc = ref.watch(presenceServiceProvider);
    final currentState = presenceSvc.currentState;
    final statusColor = _presenceColor(currentState, colors);
    final statusText = currentState.value[0].toUpperCase() + currentState.value.substring(1);

    return StreamBuilder<List<Contact>>(
      stream: pubkey != null
          ? (db.select(db.contacts)..where((c) => c.pubkey.equals(pubkey))).watch()
          : const Stream.empty(),
      builder: (context, snap) {
        final contact = snap.data?.firstOrNull;
        final displayName = contact?.displayName ?? contact?.username ?? (pubkey != null ? '${pubkey.substring(0, 8)}...' : 'User');
        final avatarUrl = contact?.avatarUrl;

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
                backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                child: avatarUrl == null
                    ? Text(displayName[0].toUpperCase(), style: TextStyle(color: colors.gray200, fontSize: 14))
                    : null,
              ),
              Positioned(
                right: -1, bottom: -1,
                child: Container(
                  width: 14, height: 14,
                  decoration: BoxDecoration(
                    color: statusColor,
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
                Text(
                  displayName,
                  style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  statusText,
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
      },
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
