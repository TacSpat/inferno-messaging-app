import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/server_rail.dart';
import '../widgets/channel_sidebar.dart';
import '../widgets/dm_sidebar.dart';
import '../widgets/member_list.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';

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
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  Server? _activeServer;
  bool _showMembers = true;

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
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold provides the Material ancestor for all child widgets
    // This fixes the yellow underline issue
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
