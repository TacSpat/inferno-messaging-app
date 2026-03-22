import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../theme/all_themes.dart';
import 'add_server_dialog.dart';

class ServerRail extends ConsumerWidget {
  final String? activeServerId;
  const ServerRail({super.key, this.activeServerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(databaseProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Container(
      width: 72,
      color: c.gray950,
      child: Column(
        children: [
          const SizedBox(height: 12),
          // Home / DM button
          _RailItem(
            icon: Icons.explore,
            tooltip: 'Direct Messages',
            isActive: activeServerId == null,
            onTap: () => context.go('/conversations'),
          ),
          // Relay status
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Container(
              width: 32, height: 2,
              decoration: BoxDecoration(
                color: c.gray800,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
          // Servers
          Expanded(
            child: StreamBuilder<List<Server>>(
              stream: db.select(db.servers).watch(),
              builder: (context, snapshot) {
                final servers = snapshot.data ?? [];
                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: servers.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final server = servers[index];
                    return _RailItem(
                      text: server.name.isNotEmpty ? server.name[0].toUpperCase() : '?',
                      imageUrl: server.iconUrl,
                      tooltip: server.name,
                      isActive: activeServerId == server.publicId,
                      onTap: () => context.go('/servers/${server.publicId}'),
                    );
                  },
                );
              },
            ),
          ),
          // Add server
          _RailItem(
            icon: Icons.add,
            tooltip: 'Add Server',
            color: const Color(0xFF16A34A),
            onTap: () async {
              final result = await showDialog<String>(
                context: context,
                builder: (_) => const AddServerDialog(),
              );
              if (result != null && context.mounted) {
                GoRouter.of(context).go('/servers/$result');
              }
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  final IconData? icon;
  final String? text;
  final String? imageUrl;
  final String? tooltip;
  final bool isActive;
  final Color? color;
  final VoidCallback? onTap;

  const _RailItem({this.icon, this.text, this.imageUrl, this.tooltip, this.isActive = false, this.color, this.onTap});

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Left active indicator bar
        if (widget.isActive)
          Positioned(
            left: 0, top: 4,
            child: Container(
              width: 3, height: 40,
              decoration: BoxDecoration(
                color: c.accentLight,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
            ),
          )
        else if (_hovering)
          Positioned(
            left: 0, top: 12,
            child: Container(
              width: 3, height: 24,
              decoration: BoxDecoration(
                color: c.gray200,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
            ),
          ),
        // Icon
        Center(
          child: Tooltip(
            message: widget.tooltip ?? '',
            preferBelow: false,
            waitDuration: const Duration(milliseconds: 500),
            child: MouseRegion(
              onEnter: (_) => setState(() => _hovering = true),
              onExit: (_) => setState(() => _hovering = false),
              child: GestureDetector(
                onTap: widget.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 48, height: 48,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    gradient: widget.isActive ? LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [c.accentDark, c.accent],
                    ) : null,
                    color: widget.isActive ? null : (_hovering ? c.gray600 : c.gray700),
                    borderRadius: BorderRadius.circular(widget.isActive || _hovering ? 16 : 24),
                    image: widget.imageUrl != null
                        ? DecorationImage(image: NetworkImage(widget.imageUrl!), fit: BoxFit.cover)
                        : null,
                  ),
                  child: widget.imageUrl == null
                      ? Center(
                          child: widget.icon != null
                              ? Icon(widget.icon, color: widget.color ?? Colors.white, size: 24)
                              : Text(widget.text ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
