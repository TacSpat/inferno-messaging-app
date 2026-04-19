import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../theme/all_themes.dart';
import '../../theme/theme_provider.dart';
import '../../providers/auth_provider.dart';
import 'package:go_router/go_router.dart';

// Import all settings pages
import 'profile_screen.dart';
import 'appearance_screen.dart';
import 'relays_screen.dart';
import 'storage_screen.dart';
import 'my_account_screen.dart';
import 'key_export_screen.dart';
import 'password_screen.dart';
import 'notifications_screen.dart';
import 'voice_video_screen.dart';
import 'safety_screen.dart';

/// Show the settings overlay
void showSettingsOverlay(BuildContext context) {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      pageBuilder: (context, animation, secondaryAnimation) => const SettingsOverlay(),
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
      transitionDuration: const Duration(milliseconds: 150),
    ),
  );
}

class SettingsOverlay extends ConsumerStatefulWidget {
  const SettingsOverlay({super.key});

  @override
  ConsumerState<SettingsOverlay> createState() => _SettingsOverlayState();
}

class _SettingsOverlayState extends ConsumerState<SettingsOverlay> {
  String _selectedPage = 'account';

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(infernoColorsProvider);

    return Scaffold(
      backgroundColor: c.gray950.withValues(alpha: 0.95),
      body: Row(
        children: [
          // Settings sidebar
          Container(
            width: 200,
            padding: const EdgeInsets.only(top: 60, left: 12, right: 4, bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel('USER SETTINGS', c),
                _NavItem('My Account', 'account', c),
                _NavItem('Profile', 'profile', c),
                _NavItem('Appearance', 'appearance', c),
                const SizedBox(height: 12),
                _SectionLabel('APP SETTINGS', c),
                _NavItem('Voice & Video', 'voice', c),
                _NavItem('Notifications', 'notifications', c),
                _NavItem('Keybinds', 'keybinds', c),
                _NavItem('Relays', 'relays', c),
                const SizedBox(height: 12),
                _SectionLabel('STORAGE', c),
                _NavItem('Storage', 'storage', c),
                const SizedBox(height: 12),
                _SectionLabel('SAFETY', c),
                _NavItem('Content Safety', 'safety', c),
                const Spacer(),
                // Divider
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  child: Container(height: 1, color: c.gray800),
                ),
                // Switch Account
                _NavItem('Switch Account', 'switch_account', c),
                // Log Out
                _NavItem('Log Out', 'logout', c, color: c.accent),
              ],
            ),
          ),
          // Main content
          Expanded(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 60, left: 20, right: 60, bottom: 16),
                  child: _buildContent(),
                ),
                // Close button
                Positioned(
                  top: 16,
                  right: 16,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 36, height: 36,
                      decoration: BoxDecoration(
                        color: c.gray800,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.gray700),
                      ),
                      child: Icon(Icons.close, color: c.gray400, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    switch (_selectedPage) {
      case 'account':
        return MyAccountScreen(onNavigate: (p) => setState(() => _selectedPage = p));
      case 'key_backup':
        return const KeyExportScreen();
      case 'password':
        return const PasswordScreen();
      case 'profile':
        return const ProfileScreen();
      case 'appearance':
        return const AppearanceScreen();
      case 'relays':
        return const RelaysScreen();
      case 'storage':
        return const StorageScreen();
      case 'voice':
        return const VoiceVideoScreen();
      case 'notifications':
        return const NotificationsScreen();
      case 'safety':
        return const SafetyScreen();
      case 'logout':
        _handleLogout();
        return const SizedBox();
      case 'switch_account':
        // Navigate to login screen which has the account picker.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final auth = ref.read(authServiceProvider);
          auth.logout();
          Navigator.pop(context);
          GoRouter.of(context).go('/auth/login');
        });
        return Center(child: CircularProgressIndicator(color: ref.read(infernoColorsProvider).accent));
      default:
        return Center(
          child: Text(
            'Coming soon',
            style: TextStyle(color: ref.read(infernoColorsProvider).gray500),
          ),
        );
    }
  }

  Future<void> _handleLogout() async {
    // Reset to prevent re-triggering
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      setState(() => _selectedPage = 'account');
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final c = ref.read(infernoColorsProvider);
          return AlertDialog(
            title: const Text('Log Out?'),
            content: const Text(
              'You will be signed out of this account. '
              'Your encrypted backup is saved and you can switch back from the login screen.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: c.accent),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Log Out'),
              ),
            ],
          );
        },
      );
      if (confirmed == true && mounted) {
        final auth = ref.read(authServiceProvider);
        // Only clear the active key — the ncryptsec stays in the account
        // list so the user can switch back from the login screen without
        // re-importing.
        await auth.logout();
        if (mounted) {
          Navigator.pop(context); // Close overlay
          GoRouter.of(context).go('/auth/login');
        }
      }
    });
  }

  Widget _NavItem(String label, String page, InfernoColors c, {Color? color}) {
    final isActive = _selectedPage == page;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => setState(() => _selectedPage = page),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isActive ? c.gray600 : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color ?? (isActive ? Colors.white : c.gray400),
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _SectionLabel(String text, InfernoColors c) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, top: 8, bottom: 4),
      child: Text(text, style: TextStyle(color: c.gray500, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
    );
  }
}
