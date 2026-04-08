import 'dart:async';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../widgets/server_rail.dart';
import '../widgets/channel_sidebar.dart';
import '../widgets/dm_sidebar.dart';
import '../widgets/member_list.dart';
import '../widgets/friend_request_bar.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/servers_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/realtime_provider.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import '../widgets/message_content.dart';
import '../widgets/message_list.dart';
import '../screens/server_settings/server_settings_overlay.dart';
import '../screens/channels/search_panel.dart';
import '../screens/channels/channel_type_router.dart';
import '../widgets/context_menu.dart';
import '../widgets/update_banner.dart';
import '../providers/server_settings_provider.dart';
import '../models/permission.dart';
import '../services/invite_service.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

class MainShell extends ConsumerStatefulWidget {
  final Widget child;
  final String? activeServerId;
  final String? activeChannelId;

  const MainShell({
    super.key,
    required this.child,
    this.activeServerId,
    this.activeChannelId,
  });

  @override
  ConsumerState<MainShell> createState() => MainShellState();
}

class MainShellState extends ConsumerState<MainShell> {
  Server? _activeServer;
  Channel? _channel;
  bool _showMembers = true;
  bool _showSearch = false;
  StreamSubscription<Channel?>? _channelSub;

  /// Saved scroll offsets per channel publicId — persists across channel navigation
  final Map<String, double> _channelScrollOffsets = {};

  /// Cached channel entries for IndexedStack — keeps visited channels alive in memory.
  /// Most-recently-used at the end. Capped at 10 to limit memory.
  static const _maxCachedChannels = 10;
  final List<({String channelId, String serverId})> _visitedChannels = [];
  String? _cachedServerId; // tracks which server the cache belongs to

  int get _activeChannelIndex {
    final idx = _visitedChannels.indexWhere((e) => e.channelId == widget.activeChannelId);
    return idx >= 0 ? idx : 0;
  }

  void _updateChannelCache() {
    final chId = widget.activeChannelId;
    final srvId = widget.activeServerId;
    if (chId == null || srvId == null) return;

    // Clear cache when switching servers
    if (_cachedServerId != null && _cachedServerId != srvId) {
      _visitedChannels.clear();
    }
    _cachedServerId = srvId;

    // Promote existing entry or add new one
    final existing = _visitedChannels.indexWhere((e) => e.channelId == chId);
    if (existing >= 0) {
      // Already cached — no reorder needed, IndexedStack just changes index
      return;
    }

    // Evict LRU if at capacity
    if (_visitedChannels.length >= _maxCachedChannels) {
      _visitedChannels.removeAt(0);
    }

    _visitedChannels.add((channelId: chId, serverId: srvId));
  }

  void toggleMemberList() {
    setState(() => _showMembers = !_showMembers);
  }

  void toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (_showSearch) _showMembers = false; // search replaces member list
    });
  }

  /// Save scroll offset for a channel
  void saveScrollOffset(String channelPublicId, double offset) {
    _channelScrollOffsets[channelPublicId] = offset;
  }

  /// Get saved scroll offset for a channel (null if not saved)
  double? getScrollOffset(String channelPublicId) {
    return _channelScrollOffsets[channelPublicId];
  }

  @override
  void didUpdateWidget(MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeServerId != widget.activeServerId) {
      _loadServer();
    }
    if (oldWidget.activeChannelId != widget.activeChannelId) {
      _loadChannel();
      _updateChannelCache();
      // Close search when switching channels
      if (_showSearch) setState(() => _showSearch = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadServer();
    _loadChannel();
    _updateChannelCache();
    _startIdleDetection();
  }

  void _startIdleDetection() {
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null && auth.publicKeyHex != null) {
      final idleSvc = ref.read(idleDetectionProvider);
      idleSvc.start(auth.privateKeyHex!, auth.publicKeyHex!);

      // Also start periodic presence publishing
      final presenceSvc = ref.read(presenceServiceProvider);
      presenceSvc.startPeriodicPublish(auth.privateKeyHex!, auth.publicKeyHex!);
    }
  }

  @override
  void dispose() {
    _channelSub?.cancel();
    super.dispose();
  }

  void _onUserActivity() {
    ref.read(idleDetectionProvider).onActivity();
  }

  void _loadChannel() {
    _channelSub?.cancel();
    if (widget.activeChannelId == null) {
      if (mounted) setState(() => _channel = null);
      return;
    }
    final db = ref.read(databaseProvider);
    final query = db.select(db.channels)..where((c) => c.publicId.equals(widget.activeChannelId!));
    _channelSub = query.watchSingleOrNull().listen((ch) {
      if (mounted) setState(() => _channel = ch);
    });
  }

  Future<void> _loadServer() async {
    if (widget.activeServerId == null) {
      if (mounted) setState(() => _activeServer = null);
      return;
    }
    final db = ref.read(databaseProvider);
    final server = await db.serversDao.getByPublicId(widget.activeServerId!);
    if (mounted) setState(() => _activeServer = server);

    // Always sync from relays to keep data fresh (structure, members, profiles)
    if (server != null && server.nostrGroupId != null) {
      _syncServerFromRelays(server);
    }
  }

  /// Sync server structure from relays when channels are missing
  Future<void> _syncServerFromRelays(Server server) async {
    if (server.nostrGroupId == null) return;
    try {
      final syncService = ref.read(serverSyncServiceProvider);
      final synced = await syncService.syncServer(server.nostrGroupId!);
      if (synced != null && mounted) {
        final db = ref.read(databaseProvider);
        final refreshed = await db.serversDao.getByPublicId(widget.activeServerId!);
        if (mounted && refreshed != null) {
          // Only update state if server metadata actually changed (avoids child widget remounts)
          if (_activeServer == null || _activeServer!.name != refreshed.name ||
              _activeServer!.iconUrl != refreshed.iconUrl || _activeServer!.bannerUrl != refreshed.bannerUrl) {
            setState(() => _activeServer = refreshed);
          }
          // Navigate to first channel if we're on the server landing page
          if (widget.activeChannelId == null) {
            final channels = await (db.select(db.channels)
                  ..where((c) => c.serverId.equals(refreshed!.id))
                  ..orderBy([(c) => OrderingTerm.asc(c.position)])
                  ..limit(1))
                .get();
            if (channels.isNotEmpty && mounted) {
              GoRouter.of(context).go('/servers/${widget.activeServerId}/channels/${channels.first.publicId}');
            }
          }
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Listener(
        onPointerDown: (_) => _onUserActivity(),
        onPointerMove: (_) => _onUserActivity(),
        behavior: HitTestBehavior.translucent,
        child: Row(
        children: [
          // Server rail (always visible)
          ServerRail(activeServerId: widget.activeServerId),

          // Everything right of the rail: unified header + content row
          Expanded(child: Column(
            children: [
              // ── Unified header bar spanning full width ──
              _UnifiedHeader(
                server: _activeServer,
                activeChannelId: widget.activeChannelId,
                onToggleMembers: toggleMemberList,
                onToggleSearch: toggleSearch,
              ),
              const FriendRequestBar(),
              const UpdateBanner(),
              // ── Content row: sidebar + main + member list ──
              Expanded(child: Row(
                children: [
                  if (_activeServer != null)
                    ChannelSidebar(
                      server: _activeServer!,
                      activeChannelId: widget.activeChannelId,
                    )
                  else
                    const DmSidebar(),
                  // Channel content: use IndexedStack cache for server channels,
                  // GoRouter child for everything else (conversations, etc.)
                  if (widget.activeServerId != null && widget.activeChannelId != null && _visitedChannels.isNotEmpty)
                    Expanded(
                      child: IndexedStack(
                        index: _activeChannelIndex,
                        children: _visitedChannels.map((entry) =>
                          ChannelTypeRouter(
                            key: ValueKey('cached-${entry.channelId}'),
                            channelPublicId: entry.channelId,
                            serverPublicId: entry.serverId,
                            isActive: entry.channelId == widget.activeChannelId,
                          ),
                        ).toList(),
                      ),
                    )
                  else
                    Expanded(child: widget.child),
                  if (_activeServer != null && widget.activeChannelId != null && _showSearch)
                    SearchPanel(
                      channelId: _channel?.id,
                      serverId: _activeServer!.id,
                      onClose: () => setState(() => _showSearch = false),
                    )
                  else if (_activeServer != null && widget.activeChannelId != null && _showMembers)
                    MemberList(serverId: _activeServer!.id),
                ],
              )),
            ],
          )),
        ],
        ),
      ),
    );
  }
}

/// Unified header bar spanning the full width (right of server rail).
/// Shows: server name | # channel name | topic | [pin] [members] [search]
class _UnifiedHeader extends ConsumerStatefulWidget {
  final Server? server;
  final String? activeChannelId;
  final VoidCallback onToggleMembers;
  final VoidCallback onToggleSearch;
  const _UnifiedHeader({this.server, this.activeChannelId, required this.onToggleMembers, required this.onToggleSearch});

  @override
  ConsumerState<_UnifiedHeader> createState() => _UnifiedHeaderState();
}

class _UnifiedHeaderState extends ConsumerState<_UnifiedHeader> {
  Channel? _channel;
  StreamSubscription<Channel?>? _channelSub;

  @override
  void initState() {
    super.initState();
    _loadChannel();
  }

  @override
  void didUpdateWidget(_UnifiedHeader old) {
    super.didUpdateWidget(old);
    if (old.activeChannelId != widget.activeChannelId) _loadChannel();
  }

  @override
  void dispose() {
    _channelSub?.cancel();
    super.dispose();
  }

  void _loadChannel() {
    _channelSub?.cancel();
    if (widget.activeChannelId == null) {
      if (mounted) setState(() => _channel = null);
      return;
    }
    final db = ref.read(databaseProvider);
    final query = db.select(db.channels)..where((c) => c.publicId.equals(widget.activeChannelId!));
    _channelSub = query.watchSingleOrNull().listen((ch) {
      if (mounted) setState(() => _channel = ch);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.gray700.withValues(alpha: 0.3))),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2, offset: const Offset(0, 1))],
      ),
      child: Row(
        children: [
          // Server/DM name section (same width as sidebar: 240px)
          if (widget.server != null)
            _ServerNameDropdown(server: widget.server!, colors: c)
          else
            SizedBox(
              width: 240,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Expanded(child: Text('Direct Messages',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14))),
                  _HeaderBtn(icon: Icons.group_add, tooltip: 'New Group Chat', colors: c, onTap: () {
                    _showGroupChatDialog(context);
                  }),
                  _HeaderBtn(icon: Icons.search, tooltip: 'Find', colors: c, onTap: () {
                    GoRouter.of(context).go('/conversations?tab=search');
                  }),
                  _HeaderBtn(icon: Icons.person_add, tooltip: 'Add Friend', colors: c, onTap: () {
                    GoRouter.of(context).go('/conversations?tab=search');
                  }),
                ]),
              ),
            ),

          // Divider
          Container(width: 1, height: 24, color: c.gray700),

          // Channel info
          if (_channel != null) ...[
            const SizedBox(width: 12),
            Icon(_channel!.encrypted ? Icons.lock : Icons.tag, size: 18, color: c.gray400),
            const SizedBox(width: 6),
            Text(_channel!.name, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
            if (_channel!.nsfw == true) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                ),
                child: const Text('NSFW', style: TextStyle(color: Colors.red, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ),
            ],
            if (_channel!.encrypted) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'End-to-end encrypted',
                child: Icon(Icons.lock, size: 14, color: Colors.green.withValues(alpha: 0.7)),
              ),
            ],
            if (_channel!.topic != null && _channel!.topic!.isNotEmpty) ...[
              const SizedBox(width: 12),
              Container(width: 1, height: 24, color: c.gray600),
              const SizedBox(width: 12),
              Expanded(child: Text(_channel!.topic!,
                style: TextStyle(color: c.gray400, fontSize: 13), overflow: TextOverflow.ellipsis)),
            ] else
              const Spacer(),
          ] else
            const Spacer(),

          // Actions
          _HeaderBtn(icon: Icons.push_pin_outlined, tooltip: 'Pinned Messages', colors: c, onTap: () {
            if (_channel != null) _showPinnedMessages(context, c, _channel!.id);
          }),
          _HeaderBtn(icon: Icons.people_outline, tooltip: 'Member List', colors: c, onTap: widget.onToggleMembers),
          const SizedBox(width: 4),
          // Search
          _HeaderBtn(icon: Icons.search, tooltip: 'Search', colors: c, onTap: widget.onToggleSearch),
          const SizedBox(width: 12),
        ],
      ),
    );
  }

  void _showPinnedMessages(BuildContext context, InfernoColors c, int channelId) {
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    // Find the pin button position to anchor the panel below it
    // The pin button is near the right side of the header
    final headerOffset = renderBox.localToGlobal(Offset.zero);

    late OverlayEntry entry;
    entry = OverlayEntry(builder: (ctx) {
      return _PinnedPanel(
        channelId: channelId,
        colors: c,
        anchorRight: 200, // right-aligned near the pin button
        anchorTop: headerOffset.dy + 48 + 4, // just below the header
        onDismiss: () => entry.remove(),
      );
    });
    overlay.insert(entry);
  }

  void _showGroupChatDialog(BuildContext context) {
    final c = ref.read(infernoColorsProvider);
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('New Group Chat', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(controller: nameCtrl, autofocus: true, style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(hintText: 'Group name', hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray900, filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () { Navigator.pop(ctx); },
                child: const Text('Create', style: TextStyle(color: Colors.white))),
            ]),
          ]),
        ),
      ),
    ).then((_) => nameCtrl.dispose());
  }
}

/// Server name dropdown in the unified header — click to show server actions menu
class _ServerNameDropdown extends ConsumerStatefulWidget {
  final Server server;
  final InfernoColors colors;
  const _ServerNameDropdown({required this.server, required this.colors});
  @override
  ConsumerState<_ServerNameDropdown> createState() => _ServerNameDropdownState();
}

class _ServerNameDropdownState extends ConsumerState<_ServerNameDropdown> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return SizedBox(
      width: 240,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: () => _showDropdown(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              gradient: _hovering ? LinearGradient(colors: [c.accent.withValues(alpha: 0.06), Colors.transparent]) : null,
            ),
            child: Row(children: [
              Expanded(child: Text(widget.server.name,
                style: TextStyle(color: c.gray50, fontWeight: FontWeight.w600, fontSize: 15),
                overflow: TextOverflow.ellipsis)),
              Icon(Icons.keyboard_arrow_down, color: c.gray400, size: 20),
            ]),
          ),
        ),
      ),
    );
  }

  void _showDropdown(BuildContext context) async {
    final c = widget.colors;
    final RenderBox box = context.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero);

    // Check permissions to gate menu items
    final permSvc = ref.read(permissionServiceProvider);
    final auth = ref.read(authServiceProvider);
    final pubkey = auth.publicKeyHex ?? '';
    final canManage = await permSvc.canManageServer(widget.server.id, pubkey);
    final canManageChannels = await permSvc.hasPermission(widget.server.id, pubkey, Permission.manageChannels);
    final canInvite = await permSvc.hasPermission(widget.server.id, pubkey, Permission.createInvite);

    if (!context.mounted) return;

    final menuPos = Offset(offset.dx + 8, offset.dy + box.size.height + 4);
    showStyledMenu(
      context: context,
      position: menuPos,
      items: [
        if (canInvite) CtxItem('Invite People', Icons.link, () {
          final inviteService = ref.read(inviteServiceProvider);
          showInviteDialog(
            context: context,
            server: widget.server,
            colors: c,
            privateKeyHex: auth.privateKeyHex!,
            publicKeyHex: auth.publicKeyHex!,
            inviteService: inviteService,
          );
        }),
        if (canManage) CtxItem('Server Settings', Icons.settings, () => showServerSettingsOverlay(context, widget.server)),
        if (canManageChannels) CtxItem('Create Channel', Icons.add, () {
          showChannelDialog(context, ref, server: widget.server, colors: c);
        }),
        if (canManageChannels) CtxItem('Create Category', Icons.create_new_folder_outlined, () {
          _createCategory(context, c);
        }),
        CtxDivider(),
        CtxItem('Leave Server', null, () => _leaveServer(context), danger: true),
      ],
    );
  }

  Future<void> _createCategory(BuildContext context, InfernoColors c) async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray900, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Create Category', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            TextField(controller: nameCtrl, autofocus: true, style: TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(hintText: 'Category name', hintStyle: TextStyle(color: c.gray500),
                fillColor: c.gray900, filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.gray700)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: c.accent)))),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()), child: const Text('Create')),
            ]),
          ]),
        ),
      ),
    );
    nameCtrl.dispose();
    if (result == null || result.isEmpty) return;
    final db = ref.read(databaseProvider);
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final categories = await (db.select(db.categories)..where((c) => c.serverId.equals(widget.server.id))).get();
    final maxPos = categories.fold<int>(0, (max, cat) => (cat.position ?? 0) > max ? (cat.position ?? 0) : max);
    await db.into(db.categories).insert(CategoriesCompanion.insert(
      publicId: publicId, serverId: widget.server.id,
      name: Value(result), position: Value(maxPos + 1),
      createdAt: now, updatedAt: now,
    ));
    final auth = ref.read(authServiceProvider);
    if (auth.privateKeyHex != null) {
      final publishSvc = ref.read(serverPublishServiceProvider);
      await publishSvc.publishStructure(privateKeyHex: auth.privateKeyHex!, publicKeyHex: auth.publicKeyHex!, server: widget.server);
    }
  }

  Future<void> _leaveServer(BuildContext context) async {
    final c = widget.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 400, padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.gray700.withValues(alpha: 0.5))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Leave Server', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('Are you sure you want to leave "${widget.server.name}"?', style: TextStyle(color: c.gray400, fontSize: 14)),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: c.gray400))),
              const SizedBox(width: 8),
              ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Leave', style: TextStyle(color: Colors.white))),
            ]),
          ]),
        ),
      ),
    );
    if (confirmed == true && context.mounted) {
      final db = ref.read(databaseProvider);
      final serverId = widget.server.id;
      await (db.delete(db.serverMemberships)..where((m) => m.serverId.equals(serverId))).go();
      final channels = await (db.select(db.channels)..where((ch) => ch.serverId.equals(serverId))).get();
      for (final ch in channels) {
        await (db.delete(db.messages)..where((m) => m.channelId.equals(ch.id))).go();
      }
      await (db.delete(db.channels)..where((ch) => ch.serverId.equals(serverId))).go();
      await (db.delete(db.categories)..where((cat) => cat.serverId.equals(serverId))).go();
      await (db.delete(db.remoteMembers)..where((m) => m.serverId.equals(serverId))).go();
      await (db.delete(db.servers)..where((s) => s.id.equals(serverId))).go();
      if (context.mounted) GoRouter.of(context).go('/conversations');
    }
  }
}

/// Floating pinned messages panel — anchored below the pin button with context-pop animation
class _PinnedPanel extends ConsumerStatefulWidget {
  final int channelId;
  final InfernoColors colors;
  final double anchorRight;
  final double anchorTop;
  final VoidCallback onDismiss;
  const _PinnedPanel({required this.channelId, required this.colors,
    required this.anchorRight, required this.anchorTop, required this.onDismiss});

  @override
  ConsumerState<_PinnedPanel> createState() => _PinnedPanelState();
}

class _PinnedPanelState extends ConsumerState<_PinnedPanel> with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _scale = Tween(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutBack));
    _opacity = Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    _anim.forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final db = ref.watch(databaseProvider);
    final screenSize = MediaQuery.of(context).size;

    // Smart positioning: anchor below pin button, clamp to screen bounds
    final maxH = (screenSize.height - widget.anchorTop - 20).clamp(200.0, 384.0);
    final right = widget.anchorRight.clamp(8.0, screenSize.width - 328);

    return Stack(children: [
      // Dismiss background
      Positioned.fill(child: GestureDetector(
        onTap: () async {
          await _anim.reverse();
          widget.onDismiss();
        },
        behavior: HitTestBehavior.opaque,
        child: Container(color: Colors.transparent),
      )),
      // Panel
      Positioned(
        right: right,
        top: widget.anchorTop,
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, child) => Opacity(
            opacity: _opacity.value,
            child: Transform.scale(
              scale: _scale.value,
              alignment: Alignment.topRight,
              child: child,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 320,
              constraints: BoxConstraints(maxHeight: maxH),
              decoration: BoxDecoration(
                color: c.gray900,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.gray700),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 16, offset: const Offset(0, 4)),
                ],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Sticky header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.gray700)),
                    borderRadius: const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8)),
                  ),
                  child: Row(children: [
                    Icon(Icons.push_pin, size: 16, color: c.idle),
                    const SizedBox(width: 8),
                    Text('Pinned Messages', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: () async { await _anim.reverse(); widget.onDismiss(); },
                        child: Icon(Icons.close, size: 16, color: c.gray400),
                      ),
                    ),
                  ]),
                ),
                // Content
                Flexible(child: StreamBuilder<List<Message>>(
                  stream: db.messagesDao.watchPinnedMessages(widget.channelId),
                  builder: (context, snapshot) {
                    final pinned = snapshot.data ?? [];
                    if (pinned.isEmpty) {
                      return Padding(padding: const EdgeInsets.all(24),
                        child: Text('No pinned messages', style: TextStyle(color: c.gray500, fontSize: 13)));
                    }
                    return ListView.separated(
                      shrinkWrap: true, padding: const EdgeInsets.all(8),
                      itemCount: pinned.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final msg = pinned[index];
                        final author = msg.nostrAuthorPubkey != null ? '${msg.nostrAuthorPubkey!.substring(0, 8)}...' : 'Unknown';
                        final time = DateFormat('MM/dd h:mm a').format(msg.createdAt.toLocal());
                        return MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () {
                              final eventId = msg.nostrEventId;
                              widget.onDismiss();
                              if (eventId != null) {
                                // Small delay to let panel close, then scroll
                                Future.delayed(const Duration(milliseconds: 250), () {
                                  MessageList.scrollToMessage(eventId);
                                });
                              }
                            },
                            child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: c.gray800, borderRadius: BorderRadius.circular(6)),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Text(author, style: TextStyle(color: c.accent, fontWeight: FontWeight.w600, fontSize: 12)),
                              const SizedBox(width: 6),
                              Text(time, style: TextStyle(color: c.gray500, fontSize: 11)),
                            ]),
                            const SizedBox(height: 4),
                            if (msg.content != null && msg.content!.isNotEmpty)
                              MessageContent(content: msg.content!, colors: c, isSpoiler: msg.spoiler),
                          ]),
                        )));
                      },
                    );
                  },
                )),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _HeaderBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _HeaderBtn({required this.icon, required this.tooltip, required this.colors, required this.onTap});
  @override
  State<_HeaderBtn> createState() => _HeaderBtnState();
}

class _HeaderBtnState extends State<_HeaderBtn> {
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
