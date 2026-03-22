import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../theme/all_themes.dart';
import '../../providers/auth_provider.dart';
import 'profile_screen.dart';
import 'appearance_screen.dart';
import 'relays_screen.dart';
import 'storage_screen.dart';
import 'key_export_screen.dart';

class SettingsHubScreen extends ConsumerWidget {
  const SettingsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<InfernoColors>()!;

    return Column(
      children: [
        // Header (matches channel header style)
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.gray900)),
          ),
          child: Row(
            children: [
              Icon(Icons.settings, size: 20, color: c.gray400),
              const SizedBox(width: 8),
              Text('Settings', style: TextStyle(color: c.gray50, fontWeight: FontWeight.w600, fontSize: 16)),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.close, color: c.gray400, size: 20),
                onPressed: () => context.go('/conversations'),
                tooltip: 'Close',
              ),
            ],
          ),
        ),
        // Settings list
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              _SectionLabel('USER SETTINGS', c),
              _SettingsItem(icon: Icons.person, title: 'Profile', subtitle: 'Display name, bio, avatar', colors: c,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()))),
              _SettingsItem(icon: Icons.palette, title: 'Appearance', subtitle: 'Theme, colors', colors: c,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearanceScreen()))),
              _SettingsItem(icon: Icons.notifications_none, title: 'Notifications', subtitle: 'Notification preferences', colors: c,
                onTap: () {}),
              _SettingsItem(icon: Icons.headset, title: 'Voice & Video', subtitle: 'Audio/video devices', colors: c,
                onTap: () {}),
              const SizedBox(height: 8),
              _SectionLabel('APP SETTINGS', c),
              _SettingsItem(icon: Icons.cell_tower, title: 'Relays', subtitle: 'Nostr relay connections', colors: c,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RelaysScreen()))),
              _SettingsItem(icon: Icons.storage, title: 'Storage', subtitle: 'Cache, pruning, backfill', colors: c,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StorageScreen()))),
              _SettingsItem(icon: Icons.shield_outlined, title: 'Safety', subtitle: 'Content filters, blocking', colors: c,
                onTap: () {}),
              const SizedBox(height: 8),
              _SectionLabel('ACCOUNT', c),
              _SettingsItem(icon: Icons.key, title: 'Key Export', subtitle: 'Backup your Nostr identity', colors: c,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const KeyExportScreen()))),
              _SettingsItem(
                icon: Icons.logout, title: 'Log Out',
                subtitle: 'Remove key from this device',
                colors: c, color: c.accent,
                onTap: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Log Out?'),
                      content: const Text('This will remove your key from this device. Make sure you have a backup (nsec or ncryptsec).'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('Log Out'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true && context.mounted) {
                    final auth = ref.read(authServiceProvider);
                    await auth.logout();
                    if (context.mounted) context.go('/auth/login');
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final InfernoColors c;
  const _SectionLabel(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 4),
      child: Text(text, style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
    );
  }
}

class _SettingsItem extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final InfernoColors colors;
  final Color? color;
  final VoidCallback onTap;

  const _SettingsItem({required this.icon, required this.title, required this.subtitle, required this.colors, this.color, required this.onTap});

  @override
  State<_SettingsItem> createState() => _SettingsItemState();
}

class _SettingsItemState extends State<_SettingsItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _hovering ? c.gray600 : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Icon(widget.icon, color: widget.color ?? c.gray400, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: TextStyle(color: widget.color ?? c.gray200, fontSize: 14, fontWeight: FontWeight.w500)),
                    Text(widget.subtitle, style: TextStyle(color: c.gray500, fontSize: 12)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.gray600, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
