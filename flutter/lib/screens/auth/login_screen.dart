import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/realtime_provider.dart';
import '../../providers/servers_provider.dart';
import '../../services/auth_service.dart';
import '../../services/app_bootstrap_service.dart';
import '../../services/media_cache_service.dart';
import '../../services/key_management_service.dart';
import '../../widgets/inferno_logo.dart';
import '../../providers/app_update_provider.dart';
import 'backup_step.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _loading = true;
  String? _error;
  List<StoredAccount> _accounts = [];
  // When true, we show the mandatory backup screen for an existing user
  // who hasn't set a backup password yet.
  bool _showBackupGate = false;
  String? _activeNpub;
  String? _activePrivHex;
  String? _activeDisplayName;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    try {
      final authService = ref.read(authServiceProvider);
      final state = await authService.initialize();
      if (!mounted) return;

      if (state == AuthState.authenticated) {
        await _bootstrap(authService);
        if (!mounted) return;

        // Gate: existing users must set a backup password before proceeding.
        final hasBackup = await KeyManagementService.hasBackupPassword();
        if (!hasBackup) {
          final npub = await KeyManagementService.exportNpub();
          setState(() {
            _showBackupGate = true;
            _activeNpub = npub;
            _activePrivHex = authService.privateKeyHex;
            _activeDisplayName = '';
            _loading = false;
          });
          return;
        }

        context.go('/conversations');
      } else {
        // Load saved accounts for the picker.
        _accounts = await KeyManagementService.listAccounts();
        setState(() => _loading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _bootstrap(AuthService authService) async {
    final db = ref.read(databaseProvider);
    final pool = ref.read(relayPoolProvider);
    final bootstrap = AppBootstrapService(
      db: db,
      relayPool: pool,
      authService: authService,
      presenceService: ref.read(presenceServiceProvider),
      typingService: ref.read(typingServiceProvider),
      reactionService: ref.read(reactionServiceProvider),
      groupMessageService: ref.read(groupMessageServiceProvider),
      dmService: ref.read(dmServiceProvider),
      contactService: ref.read(contactServiceProvider),
      inviteService: ref.read(inviteServiceProvider),
      mediaCacheService: ref.read(mediaCacheServiceProvider),
    );
    await bootstrap.bootstrap();
  }

  Future<void> _switchToAccount(StoredAccount account) async {
    // Prompt for password.
    final password = await _showPasswordDialog(account.displayName.isNotEmpty
        ? account.displayName
        : account.npub.substring(0, 16));
    if (password == null || !mounted) return;

    setState(() { _loading = true; _error = null; });
    try {
      final key = await KeyManagementService.switchAccount(account.pubkey, password);
      final authService = ref.read(authServiceProvider);
      await authService.initialize();
      if (!mounted) return;
      await _bootstrap(authService);
      if (!mounted) return;
      context.go('/conversations');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Wrong password or corrupted backup';
      });
    }
  }

  Future<void> _removeAccount(StoredAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove account?'),
        content: Text('Remove ${account.displayName.isNotEmpty ? account.displayName : account.npub.substring(0, 16)} from saved accounts? You will need to re-import the key to use it again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed != true) return;
    await KeyManagementService.removeAccount(account.pubkey);
    _accounts = await KeyManagementService.listAccounts();
    if (mounted) setState(() {});
  }

  Future<String?> _showPasswordDialog(String label) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unlock $label'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Backup Password',
            prefixIcon: Icon(Icons.lock_outline),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Unlock'),
          ),
        ],
      ),
    ).then((v) { controller.dispose(); return v; });
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    // Mandatory backup gate for existing users.
    if (_showBackupGate && _activeNpub != null && _activePrivHex != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Secure Your Identity')),
        body: SafeArea(
          child: BackupStep(
            npub: _activeNpub!,
            privateKeyHex: _activePrivHex!,
            displayName: _activeDisplayName ?? '',
            onComplete: () {
              if (mounted) context.go('/conversations');
            },
          ),
        ),
      );
    }

    if (_loading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const InfernoLogo(size: 64),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              const Text('Loading...', style: TextStyle(color: Color(0xFF8899A6))),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              const InfernoLogo(size: 80),
              const SizedBox(height: 16),
              Text(
                'Inferno',
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: primary,
                ),
              ),
              const SizedBox(height: 8),
              const Text('Nostr-native messaging', style: TextStyle(color: Color(0xFF8899A6), fontSize: 16)),
              const SizedBox(height: 12),
              Text(
                'Encrypted. Decentralized. Yours.',
                style: TextStyle(color: primary.withValues(alpha: 0.7), fontSize: 14),
              ),
              if (_error != null) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF3A1A1A), borderRadius: BorderRadius.circular(8)),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFFF4D4D), fontSize: 12)),
                ),
              ],
              const Spacer(flex: 2),

              // Saved accounts picker.
              if (_accounts.isNotEmpty) ...[
                Text('SAVED ACCOUNTS', style: TextStyle(color: const Color(0xFF8899A6), fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                const SizedBox(height: 8),
                for (final account in _accounts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => _switchToAccount(account),
                        onLongPress: () => _removeAccount(account),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFE0E0E0),
                          side: BorderSide(color: primary.withValues(alpha: 0.3)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        child: Row(children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: primary.withValues(alpha: 0.2),
                            child: Text(
                              (account.displayName.isNotEmpty ? account.displayName : account.npub)[0].toUpperCase(),
                              style: TextStyle(color: primary, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              if (account.displayName.isNotEmpty)
                                Text(account.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              Text(
                                account.npub.length > 20 ? '${account.npub.substring(0, 20)}...' : account.npub,
                                style: const TextStyle(color: Color(0xFF8899A6), fontSize: 11, fontFamily: 'monospace'),
                              ),
                            ]),
                          ),
                          const Icon(Icons.login, size: 18, color: Color(0xFF8899A6)),
                        ]),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Container(height: 1, color: const Color(0xFF2A3A5C)),
                const SizedBox(height: 12),
              ],

              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () => context.go('/auth/signup'),
                  style: ElevatedButton.styleFrom(
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  child: const Text('Create Account'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: () => context.go('/auth/import'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE0E0E0),
                    side: const BorderSide(color: Color(0xFF2A3A5C)),
                    textStyle: const TextStyle(fontSize: 16),
                  ),
                  child: const Text('Import Existing Identity'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Use an encrypted backup (ncryptsec) from another Nostr client',
                style: TextStyle(color: const Color(0xFF5C6B77), fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const Spacer(flex: 1),
              // Version info
              Consumer(builder: (context, ref, _) {
                final version = ref.watch(appVersionProvider);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    version.when(data: (v) => 'v$v', loading: () => '', error: (_, __) => ''),
                    style: const TextStyle(color: Color(0xFF5C6B77), fontSize: 11),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
