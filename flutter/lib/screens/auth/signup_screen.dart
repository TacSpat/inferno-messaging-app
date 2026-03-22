import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../services/app_bootstrap_service.dart';
import '../../crypto/bech32_nostr.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _generatedNpub;

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _loading = true; _error = null; });

    try {
      // Generate keypair
      final authService = ref.read(authServiceProvider);
      final key = await authService.signup();

      // Show the generated npub briefly
      setState(() => _generatedNpub = Bech32Nostr.npubEncode(key.publicKeyHex));

      // Bootstrap: create user record, connect relays
      final bootstrap = AppBootstrapService(
        db: ref.read(databaseProvider),
        relayPool: ref.read(relayPoolProvider),
        authService: authService,
      );
      await bootstrap.bootstrap();

      // Small delay to show the npub
      await Future.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;
      context.go('/conversations');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
                // Icon
                Icon(Icons.local_fire_department, size: 48, color: primary),
                const SizedBox(height: 16),
                Text('Choose your identity', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'A Nostr keypair will be generated for you. This is your portable, censorship-resistant identity.',
                  style: TextStyle(color: Color(0xFF8899A6)),
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    hintText: 'e.g. satoshi',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Username is required';
                    if (v.trim().length < 2) return 'At least 2 characters';
                    if (v.trim().length > 32) return 'Max 32 characters';
                    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(v.trim())) {
                      return 'Letters, numbers, _ . - only';
                    }
                    return null;
                  },
                  textInputAction: TextInputAction.next,
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _displayNameController,
                  decoration: const InputDecoration(
                    labelText: 'Display Name (optional)',
                    hintText: 'e.g. Satoshi Nakamoto',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _createAccount(),
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
                if (_generatedNpub != null) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F1629),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: primary.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.check_circle, color: primary, size: 20),
                            const SizedBox(width: 8),
                            const Text('Key generated!', style: TextStyle(color: Color(0xFF4CAF50), fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _generatedNpub!,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF8899A6)),
                        ),
                        const SizedBox(height: 8),
                        const Text('Connecting to relays...', style: TextStyle(color: Color(0xFF8899A6), fontSize: 12)),
                      ],
                    ),
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
