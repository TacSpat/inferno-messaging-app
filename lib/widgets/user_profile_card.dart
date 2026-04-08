import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' show Value;
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/realtime_provider.dart';
import '../services/presence_service.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import '../utils/url_utils.dart';
import 'package:go_router/go_router.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Show a user profile card popup with smart positioning and pop animation.
/// [anchor] is the global position of the clicked element's top-left.
/// [anchorSize] is the size of the clicked element (for alignment).
void showUserProfileCard(BuildContext context, WidgetRef ref, String pubkey, {Offset? anchor, Size? anchorSize}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _ProfileCardOverlay(
      pubkey: pubkey,
      anchor: anchor ?? _centerOf(context),
      anchorSize: anchorSize ?? Size.zero,
      onDismiss: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

Offset _centerOf(BuildContext context) {
  final size = MediaQuery.of(context).size;
  return Offset(size.width / 2, size.height / 2);
}

class _ProfileCardOverlay extends ConsumerStatefulWidget {
  final String pubkey;
  final Offset anchor;
  final Size anchorSize;
  final VoidCallback onDismiss;
  const _ProfileCardOverlay({required this.pubkey, required this.anchor, this.anchorSize = Size.zero, required this.onDismiss});
  @override
  ConsumerState<_ProfileCardOverlay> createState() => _ProfileCardOverlayState();
}

class _ProfileCardOverlayState extends ConsumerState<_ProfileCardOverlay> with SingleTickerProviderStateMixin {
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
  void dispose() { _anim.dispose(); super.dispose(); }

  Future<void> _dismiss() async {
    await _anim.reverse();
    widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);
    final db = ref.watch(databaseProvider);
    final presenceSvc = ref.watch(presenceServiceProvider);
    final presence = presenceSvc.getPresence(widget.pubkey);
    final screen = MediaQuery.of(context).size;

    // Matches Rails profile_card_controller.js positioning:
    // 1. left = element.left - 288 (to the LEFT of the element)
    // 2. top = element.top (aligned to element top)
    // 3. If goes off left: flip to element.right + 8
    // 4. If goes off bottom: shift up
    const cardW = 300.0;
    const estH = 400.0;
    final elemLeft = widget.anchor.dx;
    final elemRight = elemLeft + widget.anchorSize.width;
    final elemTop = widget.anchor.dy;

    // Try positioning to the LEFT of the element
    double left = elemLeft - cardW - 8;
    double top = elemTop;
    double alignX = 1.0; // animate from right (toward the element)
    double alignY = -1.0;

    // If card goes off the left edge, flip to the RIGHT of the element
    if (left < 8) {
      left = elemRight + 8;
      alignX = -1.0; // animate from left (toward the element)
    }

    // If card goes off the bottom, shift up
    if (top + estH > screen.height - 8) {
      top = screen.height - estH - 8;
    }

    // Final clamps
    left = left.clamp(8.0, screen.width - cardW - 8);
    top = top.clamp(8.0, screen.height - estH - 8);

    return Stack(children: [
      Positioned.fill(child: GestureDetector(
        onTap: _dismiss, onSecondaryTap: _dismiss,
        behavior: HitTestBehavior.opaque,
        child: Container(color: Colors.transparent),
      )),
      Positioned(left: left, top: top, child: AnimatedBuilder(
        animation: _anim,
        builder: (ctx, child) => Opacity(
          opacity: _opacity.value,
          child: Transform.scale(scale: _scale.value, alignment: Alignment(alignX, alignY), child: child),
        ),
        child: Material(
          color: Colors.transparent,
          child: _CardContent(
            pubkey: widget.pubkey, db: db, presenceSvc: presenceSvc,
            presence: presence, colors: c, onDismiss: _dismiss,
          ),
        ),
      )),
    ]);
  }
}

class _CardContent extends StatelessWidget {
  final String pubkey;
  final InfernoDatabase db;
  final PresenceService presenceSvc;
  final OnlineState presence;
  final InfernoColors colors;
  final VoidCallback onDismiss;
  const _CardContent({required this.pubkey, required this.db, required this.presenceSvc,
    required this.presence, required this.colors, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return FutureBuilder<_ProfileData>(
      future: _loadProfile(),
      builder: (context, snap) {
        final data = snap.data;
        if (data == null) return SizedBox(width: 300, height: 100, child: Center(child: CircularProgressIndicator(color: c.accent)));

        // Profile colors should be muted — use at 30% opacity for a subtle tint
        final rawColor1 = _parseColor(data.profileColor);
        final rawColor2 = _parseColor(data.profileColor2);
        // Use profile colors directly — matching Rails' vibrant gradient
        final profileColor1 = rawColor1 ?? c.gray700;
        final profileColor2 = rawColor2 ?? c.gray800;
        final profileTint = Color.lerp(profileColor1, profileColor2, 0.4)!;

        return DefaultTextStyle(
          style: TextStyle(decoration: TextDecoration.none, fontFamily: 'Roboto'),
          child: Container(
            width: 300,
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [profileColor1, profileColor2]),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: c.gray700.withValues(alpha: 0.6)),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 24, offset: const Offset(0, 8))],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Banner area (taller)
              Container(
                height: 90,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
                  image: validImageUrl(data.bannerUrl) != null
                      ? DecorationImage(image: NetworkImage(validImageUrl(data.bannerUrl)!), fit: BoxFit.cover)
                      : null,
                ),
              ),
              // Avatar overlapping banner
              Transform.translate(offset: const Offset(0, -32), child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  Stack(children: [
                    Container(
                      width: 72, height: 72,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: profileTint),
                      padding: const EdgeInsets.all(4),
                      child: Container(
                        width: 64, height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: validImageUrl(data.avatarUrl) != null ? Colors.transparent : c.gray700,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: validImageUrl(data.avatarUrl) != null
                            ? Image.network(validImageUrl(data.avatarUrl)!, fit: BoxFit.cover, width: 64, height: 64)
                            : Center(child: Text(data.displayName[0].toUpperCase(),
                                style: TextStyle(color: c.gray200, fontSize: 26, fontWeight: FontWeight.bold))),
                      ),
                    ),
                    Positioned(right: 2, bottom: 2, child: Container(
                      width: 18, height: 18,
                      decoration: BoxDecoration(
                        color: _presenceColor(presence, c), shape: BoxShape.circle,
                        border: Border.all(color: profileTint, width: 3),
                      ),
                    )),
                  ]),
                ]),
              )),
              const SizedBox(height: 8),
              // Dark inner card — contains name, status, roles, member since, actions
              Container(
                margin: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.gray900.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Name + username + status
                  Text(data.displayName, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  if (data.username != null && data.username != data.displayName)
                    Text(data.username!, style: TextStyle(color: c.gray400, fontSize: 13)),
                  if (data.status != null && data.status!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('${data.statusEmoji ?? ''} ${data.status!}'.trim(),
                      style: TextStyle(color: c.gray400, fontSize: 13)),
                  ],
                  if (data.bio != null && data.bio!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(height: 1, color: c.gray700.withValues(alpha: 0.5)),
                    const SizedBox(height: 8),
                    Text(data.bio!, style: TextStyle(color: c.gray200, fontSize: 13, height: 1.4),
                      maxLines: 4, overflow: TextOverflow.ellipsis),
                  ],
                  // Roles
                  if (data.roles.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Container(height: 1, color: c.gray700.withValues(alpha: 0.5)),
                    const SizedBox(height: 10),
                    Text('ROLES', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 4, runSpacing: 4, children: [
                      for (final role in data.roles)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: c.gray800,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: c.gray700),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(
                              color: _parseColor(role.color) ?? c.gray500, shape: BoxShape.circle)),
                            const SizedBox(width: 5),
                            Text(role.name ?? '', style: TextStyle(color: c.gray200, fontSize: 12, fontWeight: FontWeight.w500)),
                          ]),
                        ),
                    ]),
                  ],
                  // Member since
                  if (data.joinedAt != null) ...[
                    const SizedBox(height: 12),
                    Container(height: 1, color: c.gray700.withValues(alpha: 0.5)),
                    const SizedBox(height: 10),
                    Text('MEMBER SINCE', style: TextStyle(color: c.gray400, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
                    const SizedBox(height: 4),
                    Text('${_months[data.joinedAt!.month - 1]} ${data.joinedAt!.day}, ${data.joinedAt!.year}',
                      style: TextStyle(color: c.gray200, fontSize: 13)),
                  ],
                ]),
              ),
              // Actions outside the dark card, on the gradient
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
                child: Row(children: [
                  _CardButton(label: 'Message', icon: Icons.message_outlined, colors: c, onTap: () => _openDm(context)),
                  const SizedBox(width: 8),
                  _CardButton(label: 'Copy ID', icon: Icons.copy, colors: c, onTap: () {
                    Clipboard.setData(ClipboardData(text: pubkey));
                    onDismiss();
                  }),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Future<void> _openDm(BuildContext context) async {
    var conv = await db.contactsDao.getConversationByPubkey(pubkey);
    if (conv == null) {
      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      final contact = await db.contactsDao.getByPubkey(pubkey);
      await db.contactsDao.insertConversation(ConversationsCompanion.insert(
        publicId: publicId,
        kind: const Value(0),
        counterpartyPubkey: Value(pubkey),
        counterpartyDisplayName: Value(contact?.displayName ?? contact?.username),
        createdAt: now,
        updatedAt: now,
      ));
      conv = await db.contactsDao.getConversationByPubkey(pubkey);
    }
    if (conv != null && context.mounted) {
      onDismiss();
      GoRouter.of(context).go('/conversations/${conv.publicId}');
    }
  }

  Future<_ProfileData> _loadProfile() async {
    final contact = await db.contactsDao.getByPubkey(pubkey);
    // Get ALL remote_member records for this pubkey, pick the one with the most data
    final allMembers = await (db.select(db.remoteMembers)..where((m) => m.pubkey.equals(pubkey))).get();
    // Prefer the member record that has profile data populated
    final member = allMembers.isEmpty ? null : allMembers.reduce((best, m) {
      int score(RemoteMember rm) => [rm.displayName, rm.status, rm.profileColor, rm.avatarUrl]
          .where((v) => v != null && v.isNotEmpty).length;
      return score(m) > score(best) ? m : best;
    });

    final displayName = contact?.displayName ?? member?.displayName ?? contact?.username ?? member?.username ?? '${pubkey.substring(0, 8)}...';
    final username = contact?.username ?? member?.username;
    final avatarUrl = contact?.avatarUrl ?? member?.avatarUrl;
    final bannerUrl = contact?.bannerUrl ?? member?.bannerUrl;
    final bio = (contact?.bio?.isNotEmpty == true ? contact!.bio : null) ?? member?.bio;
    final status = member?.status ?? contact?.status;
    final statusEmoji = member?.statusEmoji ?? contact?.statusEmoji;
    // Profile colors: check all remote_member records for this pubkey
    String? profileColor = member?.profileColor;
    String? profileColor2 = member?.profileColor2;
    if (profileColor == null || profileColor.isEmpty) {
      final allForPubkey = await (db.select(db.remoteMembers)
        ..where((m) => m.pubkey.equals(pubkey))
        ..limit(5)).get();
      for (final rm in allForPubkey) {
        if (rm.profileColor != null && rm.profileColor!.isNotEmpty) {
          profileColor = rm.profileColor;
          profileColor2 = rm.profileColor2;
          break;
        }
      }
    }
    // Load roles from ALL member records for this pubkey (across servers)
    List<Role> roles = [];
    final allRoleIds = <int>{};
    for (final rm in allMembers) {
      final assignments = await (db.select(db.remoteMembershipRoles)
        ..where((r) => r.remoteMemberId.equals(rm.id))).get();
      allRoleIds.addAll(assignments.map((a) => a.roleId));
    }
    if (allRoleIds.isNotEmpty) {
      roles = await (db.select(db.roles)..where((r) => r.id.isIn(allRoleIds.toList()))).get();
      roles.sort((a, b) => (b.position ?? 0).compareTo(a.position ?? 0));
    }

    debugPrint('[ProfileCard] $pubkey color=$profileColor status=$status emoji=$statusEmoji roles=${roles.length}');

    final joinedAt = member?.joinedAt != null && member!.joinedAt!.year > 2000 ? member.joinedAt : member?.createdAt;

    return _ProfileData(
      displayName: displayName, username: username, avatarUrl: avatarUrl,
      bannerUrl: bannerUrl, bio: bio, status: status, statusEmoji: statusEmoji,
      profileColor: profileColor, profileColor2: profileColor2,
      roles: roles, joinedAt: joinedAt,
    );
  }

  static Color _presenceColor(OnlineState state, InfernoColors c) => switch (state) {
    OnlineState.online => c.online,
    OnlineState.idle => c.idle,
    OnlineState.dnd => c.dnd,
    _ => c.offline,
  };

  static Color? _parseColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    try {
      final cleaned = hex.replaceFirst('#', '');
      if (cleaned.length == 6) return Color(int.parse('FF$cleaned', radix: 16));
    } catch (_) {}
    return null;
  }
}

class _ProfileData {
  final String displayName;
  final String? username, avatarUrl, bannerUrl, bio, status, statusEmoji, profileColor, profileColor2;
  final List<Role> roles;
  final DateTime? joinedAt;
  _ProfileData({required this.displayName, this.username, this.avatarUrl, this.bannerUrl,
    this.bio, this.status, this.statusEmoji, this.profileColor, this.profileColor2,
    required this.roles, this.joinedAt});
}

class _CardButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final InfernoColors colors;
  final VoidCallback onTap;
  const _CardButton({required this.label, required this.icon, required this.colors, required this.onTap});
  @override
  State<_CardButton> createState() => _CardButtonState();
}

class _CardButtonState extends State<_CardButton> {
  bool _hovering = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _hovering ? c.accent.withValues(alpha: 0.15) : c.gray700,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(widget.icon, size: 14, color: c.gray200),
            const SizedBox(width: 6),
            Text(widget.label, style: TextStyle(color: c.gray200, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}
