import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../widgets/server_rail.dart';
import '../widgets/channel_sidebar.dart';
import '../widgets/dm_sidebar.dart';
import '../widgets/member_list.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/servers_provider.dart';

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
  bool _showMembers = true;

  void toggleMemberList() {
    setState(() => _showMembers = !_showMembers);
  }

  @override
  void didUpdateWidget(MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeServerId != widget.activeServerId) {
      _loadServer();
    }
  }

  @override
  void initState() {
    super.initState();
    _loadServer();
  }

  Future<void> _loadServer() async {
    if (widget.activeServerId == null) {
      if (mounted) setState(() => _activeServer = null);
      return;
    }
    final db = ref.read(databaseProvider);
    final server = await db.serversDao.getByPublicId(widget.activeServerId!);
    if (mounted) setState(() => _activeServer = server);

    // Auto-sync from relays if server has no channels (needs backfill)
    if (server != null && server.nostrGroupId != null) {
      final channels = await (db.select(db.channels)
            ..where((c) => c.serverId.equals(server.id)))
          .get();
      if (channels.isEmpty) {
        _syncServerFromRelays(server);
      }
    }
  }

  /// Sync server structure from relays when channels are missing
  Future<void> _syncServerFromRelays(Server server) async {
    if (server.nostrGroupId == null) return;
    try {
      final syncService = ref.read(serverSyncServiceProvider);
      final synced = await syncService.syncServer(server.nostrGroupId!);
      if (synced != null && mounted) {
        // Reload server to pick up any metadata updates
        final db = ref.read(databaseProvider);
        final refreshed = await db.serversDao.getByPublicId(widget.activeServerId!);
        if (mounted) {
          setState(() => _activeServer = refreshed);
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
      body: Row(
        children: [
          // Server rail (always visible)
          ServerRail(activeServerId: widget.activeServerId),

          // Sidebar: DM sidebar when no server, channel sidebar when server selected
          if (_activeServer != null)
            ChannelSidebar(
              server: _activeServer!,
              activeChannelId: widget.activeChannelId,
            )
          else
            const DmSidebar(),

          // Main content area
          Expanded(child: widget.child),

          // Member list (only when viewing a server channel)
          if (_activeServer != null && widget.activeChannelId != null && _showMembers)
            MemberList(serverId: _activeServer!.id),
        ],
      ),
    );
  }
}
