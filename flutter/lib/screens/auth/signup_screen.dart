import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/realtime_provider.dart';
import '../../providers/servers_provider.dart';
import '../../widgets/inferno_logo.dart';
import '../../services/app_bootstrap_service.dart';
import '../../services/media_cache_service.dart';
import '../../services/key_management_service.dart';
import '../../providers/conversations_provider.dart';
import '../../crypto/bech32_nostr.dart';
import '../../crypto/nip49_crypto.dart';
import 'backup_step.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _generatedNpub;
  String? _privateKeyHex;
  int _step = 0; // 0 = form, 1 = mandatory backup

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });

    try {
      // Generate keypair
      final authService = ref.read(authServiceProvider);
      final key = await authService.signup();

      setState(() {
        _generatedNpub = Bech32Nostr.npubEncode(key.publicKeyHex);
        _privateKeyHex = key.privateKeyHex;
      });

      // Bootstrap: create user record, connect relays
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

      // Publish Kind 0 profile metadata so other users can resolve our name.
      try {
        final name = _nameController.text.trim();
        await ref.read(profileServiceProvider).publishProfile(
              privateKeyHex: key.privateKeyHex,
              publicKeyHex: key.publicKeyHex,
              username: name,
              displayName: name,
            );
      } catch (e) {
        debugPrint('[Signup] Failed to publish profile metadata: $e');
      }

      if (!mounted) return;
      // Move to the mandatory backup step instead of navigating to the app.
      setState(() { _step = 1; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _onBackupComplete() {
    if (!mounted) return;
    context.go('/conversations');
  }

  @override
  Widget build(BuildContext context) {
    if (_step == 1) {
      return Scaffold(
        appBar: AppBar(title: const Text('Secure Your Identity')),
        body: SafeArea(
          child: BackupStep(
            npub: _generatedNpub!,
            privateKeyHex: _privateKeyHex!,
            displayName: _nameController.text.trim(),
            onComplete: _onBackupComplete,
          ),
        ),
      );
    }

    final primary = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/auth/login'),
        ),
        title: const Text('Create Account'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),
                const InfernoLogo(size: 48),
                const SizedBox(height: 16),
                Text('Choose your identity', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'A Nostr keypair will be generated for you. This is your portable, censorship-resistant identity.',
                  style: TextStyle(color: Color(0xFF8899A6)),
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    hintText: 'e.g. Satoshi Nakamoto',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Display name is required';
                    if (v.trim().length < 2) return 'At least 2 characters';
                    if (v.trim().length > 50) return 'Max 50 characters';
                    return null;
                  },
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _createAccount(),
                  autofocus: true,
                ),
                const SizedBox(height: 32),
                if (_error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3A1A1A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_error!, style: const TextStyle(color: Color(0xFFFF4D4D))),
                  ),
                  const SizedBox(height: 16),
                ],
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _createAccount,
                    child: _loading
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                              SizedBox(width: 12),
                              Text('Creating identity...'),
                            ],
                          )
                        : const Text('Generate Key & Create Account'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
