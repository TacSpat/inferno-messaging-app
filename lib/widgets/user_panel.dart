import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/realtime_provider.dart';
import '../providers/app_update_provider.dart';
import '../database/database.dart';
import '../services/presence_service.dart';
import '../theme/all_themes.dart';
import '../theme/theme_provider.dart';
import '../screens/settings/settings_overlay.dart';

/// Bottom-left user pill (avatar / name / presence / settings).
///
/// Rendered once by MainShell so it keeps its state across DM ↔ server
/// sidebar swaps. Previously each sidebar owned a private copy that rebuilt
/// on every swap, causing a visible flicker.
class UserPanel extends ConsumerWidget {
  const UserPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authServiceProvider);
    final colors = ref.watch(infernoColorsProvider);
    final pubkey = auth.publicKeyHex;
    final db = ref.watch(databaseProvider);
    final presenceSvc = ref.watch(presenceServiceProvider);
    // Subscribe to presence updates so the panel re-renders when our own
    // state changes (idle detection, manual status change, etc).
    ref.watch(presenceUpdatesProvider);
    // Use the same source as the member list so the two indicators never
    // disagree. `getPresence` returns the value in the shared tracking map,
    // which is kept in sync for self + everyone else.
    final currentState = pubkey != null
        ? presenceSvc.getPresence(pubkey)
        : presenceSvc.currentState;
    final statusColor = _presenceColor(currentState, colors);
    final statusText = currentState.value[0].toUpperCase() + currentState.value.substring(1);

    return StreamBuilder<List<Contact>>(
      stream: pubkey != null
          ? (db.select(db.contacts)..where((c) => c.pubkey.equals(pubkey))).watch()
          : const Stream.empty(),
      builder: (context, snap) {
        final contact = snap.data?.firstOrNull;
        final displayName = contact?.displayName ??
            contact?.username ??
            (pubkey != null ? '${pubkey.substring(0, 8)}...' : 'User');
        final avatarUrl = contact?.avatarUrl;

        return Container(
          // Match the sidebar above so the user panel blends into the column
          // instead of breaking with a darker strip at the bottom.
          color: colors.gray800,
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: colors.gray950,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: avatarUrl != null && avatarUrl.startsWith('http')
                            ? Colors.transparent
                            : colors.gray700,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: avatarUrl != null && avatarUrl.startsWith('http')
                          ? Image.network(avatarUrl, fit: BoxFit.cover, width: 32, height: 32)
                          : Center(
                              child: Text(
                                displayName[0].toUpperCase(),
                                style: TextStyle(color: colors.gray200, fontSize: 14, fontWeight: FontWeight.w600),
                              ),
                            ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: colors.gray600, width: 2),
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
                      Text(displayName,
                          style: TextStyle(color: colors.gray200, fontSize: 13, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis),
                      Text(statusText, style: TextStyle(color: colors.gray500, fontSize: 11)),
                    ],
                  ),
                ),
                ref.watch(appVersionProvider).when(
                      data: (v) => Text('v$v', style: TextStyle(color: colors.gray500, fontSize: 10)),
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                    ),
                const SizedBox(width: 6),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => showSettingsOverlay(context),
                    child: Icon(Icons.settings, color: colors.gray400, size: 18),
                  ),
                ),
              ],
            ),
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
