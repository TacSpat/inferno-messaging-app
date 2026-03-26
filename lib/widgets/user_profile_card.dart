import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/realtime_provider.dart';
import '../services/presence_service.dart';
import '../theme/all_themes.dart';

/// Show a user profile card popup anchored near the click position
void showUserProfileCard(BuildContext context, WidgetRef ref, String pubkey, {Offset? anchor}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _ProfileCardOverlay(
      pubkey: pubkey,
      anchor: anchor ?? Offset(MediaQuery.of(context).size.width / 2, MediaQuery.of(context).size.height / 2),
      onDismiss: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _ProfileCardOverlay extends ConsumerWidget {
  final String pubkey;
  final Offset anchor;
  final VoidCallback onDismiss;
  const _ProfileCardOverlay({required this.pubkey, required this.anchor, required this.onDismiss});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<InfernoColors>()!;
    final db = ref.watch(databaseProvider);
    final presenceSvc = ref.watch(presenceServiceProvider);
    final presence = presenceSvc.getPresence(pubkey);

    return Stack(children: [
      // Dismiss background
      Positioned.fill(child: GestureDetector(onTap: onDismiss, behavior: HitTestBehavior.opaque, child: Container(color: Colors.transparent))),
      // Card
      Positioned(
        left: (anchor.dx + 300 > MediaQuery.of(context).size.width) ? anchor.dx - 320 : anchor.dx + 8,
        top: (anchor.dy + 400 > MediaQuery.of(context).size.height) ? anchor.dy - 300 : anchor.dy,
        child: Material(
          color: Colors.transparent,
          child: FutureBuilder<Contact?>(
            future: db.contactsDao.getByPubkey(pubkey),
            builder: (context, contactSnap) {
              // Also try remote members
              return FutureBuilder<List<RemoteMember>>(
                future: (db.select(db.remoteMembers)..where((m) => m.pubkey.equals(pubkey))..limit(1)).get(),
                builder: (context, memberSnap) {
                  final contact = contactSnap.data;
                  final member = memberSnap.data?.firstOrNull;

                  final displayName = contact?.displayName ?? member?.displayName ?? contact?.username ?? member?.username ?? '${pubkey.substring(0, 8)}...';
                  final username = contact?.username ?? member?.username;
                  final avatarUrl = contact?.avatarUrl ?? member?.avatarUrl;
                  final bannerUrl = contact?.bannerUrl ?? member?.bannerUrl;
                  final bio = contact?.bio ?? member?.bio;
                  final nip05 = contact?.nip05;

                  return Container(
                    width: 300,
                    decoration: BoxDecoration(
                      color: c.gray800,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: c.gray700),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 20, offset: const Offset(0, 8))],
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // Banner
                      Container(
                        height: 60,
                        decoration: BoxDecoration(
                          color: c.accent.withValues(alpha: 0.3),
                          borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
                          image: bannerUrl != null ? DecorationImage(image: NetworkImage(bannerUrl), fit: BoxFit.cover) : null,
                        ),
                      ),
                      // Avatar overlapping banner
                      Transform.translate(
                        offset: const Offset(0, -24),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(children: [
                            Stack(children: [
                              CircleAvatar(
                                radius: 32, backgroundColor: Colors.transparent,
                                backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                child: avatarUrl == null ? Text(displayName[0].toUpperCase(), style: TextStyle(color: c.gray200, fontSize: 24)) : null,
                              ),
                              Positioned(right: 0, bottom: 0, child: Container(
                                width: 16, height: 16,
                                decoration: BoxDecoration(
                                  color: _presenceColor(presence, c),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: c.gray800, width: 3),
                                ),
                              )),
                            ]),
                          ]),
                        ),
                      ),
                      // Info
                      Padding(
                        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 16),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(displayName, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          if (username != null && username != displayName)
                            Text(username, style: TextStyle(color: c.gray400, fontSize: 13)),
                          if (nip05 != null && nip05.isNotEmpty)
                            Row(children: [
                              Icon(Icons.verified, size: 14, color: c.accent),
                              const SizedBox(width: 4),
                              Text(nip05, style: TextStyle(color: c.gray400, fontSize: 12)),
                            ]),
                          if (bio != null && bio.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Container(height: 1, color: c.gray700),
                            const SizedBox(height: 8),
                            Text(bio, style: TextStyle(color: c.gray200, fontSize: 13, height: 1.4), maxLines: 4, overflow: TextOverflow.ellipsis),
                          ],
                          const SizedBox(height: 12),
                          // Action buttons
                          Row(children: [
                            _CardButton(label: 'Message', icon: Icons.message_outlined, colors: c, onTap: () { onDismiss(); }),
                            const SizedBox(width: 8),
                            _CardButton(label: 'Copy ID', icon: Icons.copy, colors: c, onTap: () {
                              Clipboard.setData(ClipboardData(text: pubkey));
                              onDismiss();
                            }),
                          ]),
                        ]),
                      ),
                    ]),
                  );
                },
              );
            },
          ),
        ),
      ),
    ]);
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
