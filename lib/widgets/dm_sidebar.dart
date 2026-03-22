import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../services/auth_service.dart';
import '../theme/all_themes.dart';
import '../screens/settings/settings_overlay.dart';

class DmSidebar extends ConsumerWidget {
  const DmSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final conversationsAsync = ref.watch(conversationsStreamProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;
    final currentPath = GoRouterState.of(context).uri.toString();
    final isFriendsActive = currentPath == '/conversations';

    return Container(
      width: 240,
      color: c.gray800,
      child: Column(
        children: [
          // Header
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.gray900)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text('Direct Messages',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                ),
                _HeaderButton(icon: Icons.group_add, tooltip: 'New Group Chat', colors: c, onTap: () {}),
                _HeaderButton(icon: Icons.search, tooltip: 'Find conversation', colors: c, onTap: () {}),
                _HeaderButton(icon: Icons.person_add, tooltip: 'Add Friend', colors: c, onTap: () {
                  context.go('/conversations?tab=search');
                }),
              ],
            ),
          ),

          // Nav + conversations
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              children: [
                // Friends link
                _NavItem(
                  icon: Icons.person,
                  label: 'Friends',
                  isActive: isFriendsActive,
                  colors: c,
                  onTap: () => context.go('/conversations'),
                ),
                const SizedBox(height: 4),
                // Conversation list
                conversationsAsync.when(
                  data: (conversations) {
                    if (conversations.isEmpty) return const SizedBox();
                    return Column(
                      children: conversations.map((conv) {
                        final name = conv.counterpartyDisplayName
                            ?? conv.name
                            ?? conv.counterpartyPubkey?.substring(0, 12)
                            ?? 'Unknown';
                        final isActive = currentPath.contains(conv.publicId);
                        return _ConversationItem(
                          name: name,
                          isGroup: conv.kind == 1,
                          isActive: isActive,
                          colors: c,
                          onTap: () => context.go('/conversations/${conv.publicId}'),
                        );
                      }).toList(),
                    );
                  },
                  loading: () => const SizedBox(),
                  error: (_, __) => const SizedBox(),
                ),
              ],
            ),
          ),

          // User panel
          _UserPanel(auth: auth, colors: c),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _HeaderButton({required this.icon, required this.tooltip, required this.colors, required this.onTap});

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 32, height: 32,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: _hovering ? widget.colors.gray700 : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(widget.icon, size: 20,
              color: _hovering ? Colors.white : widget.colors.gray400),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _NavItem({required this.icon, required this.label, required this.isActive, required this.colors, required this.onTap});

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final active = widget.isActive;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active ? c.gray700 : (_hovering ? c.gray700 : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 20,
                color: active ? Colors.white : c.gray400),
              const SizedBox(width: 12),
              Text(widget.label, style: TextStyle(
                color: active ? Colors.white : (_hovering ? c.gray200 : c.gray400),
                fontWeight: FontWeight.w500, fontSize: 14,
              )),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversationItem extends StatefulWidget {
  final String name;
  final bool isGroup;
  final bool isActive;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _ConversationItem({required this.name, required this.isGroup, required this.isActive, required this.colors, required this.onTap});

  @override
  State<_ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends State<_ConversationItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final active = widget.isActive;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: active ? c.gray700 : (_hovering ? c.gray700 : Colors.transparent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              // Avatar
              Stack(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: widget.isGroup ? c.accentDark.withValues(alpha: 0.3) : c.gray600,
                    child: widget.isGroup
                        ? Icon(Icons.group, size: 16, color: c.accentLight)
                        : Text(widget.name[0].toUpperCase(),
                            style: TextStyle(color: c.gray200, fontSize: 13, fontWeight: FontWeight.bold)),
                  ),
                  // Online status dot
                  if (!widget.isGroup)
                    Positioned(
                      right: -2, bottom: -2,
                      child: Container(
                        width: 14, height: 14,
                        decoration: BoxDecoration(
                          color: c.offline,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.gray800, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.name, style: TextStyle(
                  color: active ? Colors.white : (_hovering ? c.gray200 : c.gray400),
                  fontSize: 14, fontWeight: FontWeight.w500,
                ), overflow: TextOverflow.ellipsis),
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
                Text(shortName, style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis),
                Text('Online', style: TextStyle(color: colors.gray400, fontSize: 11)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => showSettingsOverlay(context),
            child: Icon(Icons.settings, color: colors.gray400, size: 16),
          ),
        ],
      ),
    );
  }
}
