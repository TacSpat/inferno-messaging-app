import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/conversations_provider.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../theme/all_themes.dart';

/// Top bar showing pending incoming friend requests with accept/decline/dismiss carousel.
/// Matches Rails _friend_request_bar.html.erb — gradient background with fire shimmer.
class FriendRequestBar extends ConsumerStatefulWidget {
  const FriendRequestBar({super.key});

  @override
  ConsumerState<FriendRequestBar> createState() => _FriendRequestBarState();
}

class _FriendRequestBarState extends ConsumerState<FriendRequestBar> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pendingAsync = ref.watch(pendingRequestsStreamProvider);
    final c = Theme.of(context).extension<InfernoColors>()!;

    return pendingAsync.when(
      data: (pending) {
        if (pending.isEmpty) return const SizedBox.shrink();
        final index = _currentIndex.clamp(0, pending.length - 1);
        final contact = pending[index];
        final name = contact.displayName ?? contact.username ?? '${contact.pubkey.substring(0, 8)}...';
        final avatarUrl = contact.avatarUrl;
        final hasValidAvatar = avatarUrl != null && avatarUrl.startsWith('http');

        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [c.gray950.withValues(alpha: 0.97), c.accent.withValues(alpha: 0.15)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            border: Border(bottom: BorderSide(color: c.accent.withValues(alpha: 0.5), width: 2)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          height: 44,
          child: Row(
            children: [
              // Prev arrow
              if (pending.length > 1)
                _NavArrow(icon: Icons.chevron_left, colors: c,
                  onTap: () => setState(() => _currentIndex = (index - 1).clamp(0, pending.length - 1))),

              // Avatar
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.gray700,
                  image: hasValidAvatar
                      ? DecorationImage(image: NetworkImage(avatarUrl!), fit: BoxFit.cover)
                      : null,
                ),
                child: !hasValidAvatar
                    ? Center(child: Text(name[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 12, fontWeight: FontWeight.bold)))
                    : null,
              ),
              const SizedBox(width: 10),

              // Name + "wants to be friends"
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: name, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                    TextSpan(text: ' wants to be friends', style: TextStyle(color: c.gray400, fontSize: 13)),
                  ]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // Counter
              if (pending.length > 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text('${index + 1}/${pending.length}', style: TextStyle(color: c.gray500, fontSize: 11)),
                ),

              // Next arrow
              if (pending.length > 1)
                _NavArrow(icon: Icons.chevron_right, colors: c,
                  onTap: () => setState(() => _currentIndex = (index + 1).clamp(0, pending.length - 1))),

              // Divider
              Container(width: 1, height: 20, color: c.gray600.withValues(alpha: 0.5), margin: const EdgeInsets.symmetric(horizontal: 6)),

              // Accept
              _ActionBtn(
                icon: Icons.check, color: c.online, tooltip: 'Accept',
                onTap: () => _accept(contact),
              ),
              // Decline
              _ActionBtn(
                icon: Icons.close, color: c.accent, tooltip: 'Decline',
                onTap: () => _decline(contact),
              ),
              // Dismiss (ignore)
              _ActionBtn(
                icon: Icons.visibility_off, color: c.gray500, tooltip: 'Dismiss',
                onTap: () => _ignore(contact),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Future<void> _accept(Contact contact) async {
    final auth = ref.read(authServiceProvider);
    final dmService = ref.read(dmServiceProvider);
    if (auth.privateKeyHex == null) return;

    // Update local status FIRST so the bar disappears immediately
    final db = ref.read(databaseProvider);
    await (db.update(db.contacts)..where((c) => c.pubkey.equals(contact.pubkey)))
        .write(ContactsCompanion(friendshipStatus: const Value(3), updatedAt: Value(DateTime.now())));

    // Then send the response DM (which also updates status, but bar is already gone)
    await dmService.sendFriendResponse(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      recipientPubkey: contact.pubkey,
      status: 'accepted',
    );
  }

  Future<void> _decline(Contact contact) async {
    // Update local status FIRST
    final db = ref.read(databaseProvider);
    await (db.update(db.contacts)..where((c) => c.pubkey.equals(contact.pubkey)))
        .write(ContactsCompanion(friendshipStatus: const Value(4), updatedAt: Value(DateTime.now())));

    final auth = ref.read(authServiceProvider);
    final dmService = ref.read(dmServiceProvider);
    if (auth.privateKeyHex == null) return;
    await dmService.sendFriendResponse(
      privateKeyHex: auth.privateKeyHex!,
      publicKeyHex: auth.publicKeyHex!,
      recipientPubkey: contact.pubkey,
      status: 'declined',
    );
  }

  Future<void> _ignore(Contact contact) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.contacts)..where((c) => c.pubkey.equals(contact.pubkey)))
        .write(ContactsCompanion(friendshipStatus: const Value(0), updatedAt: Value(DateTime.now())));
  }
}

class _NavArrow extends StatefulWidget {
  final IconData icon;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _NavArrow({required this.icon, required this.colors, required this.onTap});
  @override
  State<_NavArrow> createState() => _NavArrowState();
}

class _NavArrowState extends State<_NavArrow> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(widget.icon, size: 16,
            color: _hovering ? widget.colors.gray200 : widget.colors.gray500),
        ),
      ),
    );
  }
}

class _ActionBtn extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  const _ActionBtn({required this.icon, required this.color, required this.tooltip, required this.onTap});
  @override
  State<_ActionBtn> createState() => _ActionBtnState();
}

class _ActionBtnState extends State<_ActionBtn> {
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
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _hovering ? widget.color.withValues(alpha: 0.2) : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(widget.icon, size: 18, color: widget.color),
          ),
        ),
      ),
    );
  }
}
