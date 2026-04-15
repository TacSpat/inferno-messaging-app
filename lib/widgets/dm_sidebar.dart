import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/database_provider.dart';
import '../providers/realtime_provider.dart';
import '../providers/unread_provider.dart';
import '../providers/app_update_provider.dart';
import '../database/database.dart';
import '../services/auth_service.dart';
import '../services/presence_service.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import '../screens/settings/settings_overlay.dart';

class DmSidebar extends ConsumerWidget {
  const DmSidebar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final conversationsAsync = ref.watch(conversationsStreamProvider);
    final c = ref.watch(infernoColorsProvider);
    final currentPath = GoRouterState.of(context).uri.toString();
    final isFriendsActive = currentPath == '/conversations';
    final presenceSvc = ref.watch(presenceServiceProvider);

    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: c.gray800,
        border: Border(right: BorderSide(color: c.accent.withValues(alpha: 0.08), width: 1)),
      ),
      child: Column(
        children: [
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
                        // Get presence for counterparty
                        final presenceState = conv.counterpartyPubkey != null
                            ? presenceSvc.getPresence(conv.counterpartyPubkey!)
                            : OnlineState.offline;
                        return _ConversationItem(
                          conversationId: conv.id,
                          name: name,
                          counterpartyPubkey: conv.counterpartyPubkey,
                          isGroup: conv.kind == 1,
                          isActive: isActive,
                          presenceState: presenceState,
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

void _showGroupChatDialog(BuildContext context, WidgetRef ref, InfernoColors c) {
  final nameCtrl = TextEditingController();
  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.gray900,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.gray700.withValues(alpha: 0.5)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('New Group Chat', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Text('GROUP NAME', style: TextStyle(color: c.gray400, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          TextField(
            controller: nameCtrl, autofocus: true,
            style: TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'My Group Chat',
              hintStyle: TextStyle(color: c.gray500),
              fillColor: c.gray900, filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.gray700)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: c.accent)),
            ),
          ),
          const SizedBox(height: 8),
          Text('You can add members after creating the group.', style: TextStyle(color: c.gray500, fontSize: 12)),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: c.gray400))),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: c.accent),
              onPressed: () async {
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                final db = ref.read(databaseProvider);
                final now = DateTime.now();
                final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
                await db.into(db.conversations).insert(ConversationsCompanion.insert(
                  publicId: publicId,
                  kind: const Value(1), // group_chat
                  name: Value(name),
                  createdAt: now,
                  updatedAt: now,
                ));
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Create', style: TextStyle(color: Colors.white)),
            ),
          ]),
        ]),
      ),
    ),
  ).then((_) => nameCtrl.dispose());
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
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 32, height: 32,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              gradient: _hovering ? LinearGradient(colors: [widget.colors.accent.withValues(alpha: 0.08), Colors.transparent]) : null,
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
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            gradient: (active || _hovering) ? LinearGradient(colors: [c.accent.withValues(alpha: active ? 0.12 : 0.08), Colors.transparent]) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 20, color: active ? Colors.white : c.gray400),
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

class _ConversationItem extends ConsumerStatefulWidget {
  final int conversationId;
  final String name;
  final String? counterpartyPubkey;
  final bool isGroup;
  final bool isActive;
  final OnlineState presenceState;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _ConversationItem({required this.conversationId, required this.name, required this.counterpartyPubkey, required this.isGroup, required this.isActive, required this.presenceState, required this.colors, required this.onTap});

  @override
  ConsumerState<_ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends ConsumerState<_ConversationItem> {
  bool _hovering = false;

  Color _statusColor() {
    final c = widget.colors;
    switch (widget.presenceState) {
      case OnlineState.online: return c.online;
      case OnlineState.idle: return c.idle;
      case OnlineState.dnd: return c.dnd;
      default: return c.offline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final active = widget.isActive;
    final unreadCount = ref.watch(conversationUnreadCountProvider(widget.conversationId)).valueOrNull ?? 0;
    final hasUnread = !active && unreadCount > 0;
    final db = ref.watch(databaseProvider);

    // Watch the contact row so the avatar updates live when profile syncs
    final pubkey = widget.counterpartyPubkey;
    final contactStream = (pubkey != null && !widget.isGroup)
        ? (db.select(db.contacts)..where((c) => c.pubkey.equals(pubkey))).watchSingleOrNull()
        : Stream<Contact?>.value(null);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            gradient: (active || _hovering) ? LinearGradient(colors: [c.accent.withValues(alpha: active ? 0.12 : 0.08), Colors.transparent]) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              StreamBuilder<Contact?>(
                stream: contactStream,
                builder: (context, snap) {
                  final avatarUrl = snap.data?.avatarUrl;
                  return Stack(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: widget.isGroup
                            ? c.accentDark.withValues(alpha: 0.3)
                            : c.gray700,
                        backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                            ? NetworkImage(avatarUrl)
                            : null,
                        child: widget.isGroup
                            ? Icon(Icons.group, size: 16, color: c.accentLight)
                            : (avatarUrl == null || avatarUrl.isEmpty
                                ? Text(widget.name[0].toUpperCase(),
                                    style: TextStyle(color: c.gray200, fontSize: 13, fontWeight: FontWeight.bold))
                                : null),
                      ),
                      if (!widget.isGroup)
                        Positioned(
                          right: -2, bottom: -2,
                          child: Container(
                            width: 14, height: 14,
                            decoration: BoxDecoration(
                              color: _statusColor(),
                              shape: BoxShape.circle,
                              border: Border.all(color: c.gray800, width: 2),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(widget.name, style: TextStyle(
                  color: active ? Colors.white : (hasUnread ? Colors.white : (_hovering ? c.gray200 : c.gray400)),
                  fontSize: 14, fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
                ), overflow: TextOverflow.ellipsis),
              ),
              // Unread badge
              if (hasUnread)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: c.gray600,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text('$unreadCount', style: const TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600,
                  )),
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
              Stack(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.transparent,
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
                    Text(displayName, style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                      overflow: TextOverflow.ellipsis),
                    Text(statusText, style: TextStyle(color: colors.gray400, fontSize: 11)),
                  ],
                ),
              ),
              ref.watch(appVersionProvider).when(
                data: (v) => Text('v$v', style: TextStyle(color: colors.gray500, fontSize: 10)),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => showSettingsOverlay(context),
                child: Icon(Icons.settings, color: colors.gray400, size: 16),
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
