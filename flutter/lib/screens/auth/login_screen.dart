import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/database_provider.dart';
import '../../services/auth_service.dart';
import '../../services/app_bootstrap_service.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _loading = true;
  String? _error;

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
        // Bootstrap and navigate
        final bootstrap = AppBootstrapService(
          db: ref.read(databaseProvider),
          relayPool: ref.read(relayPoolProvider),
          authService: authService,
        );
        await bootstrap.bootstrap();
        if (!mounted) return;
        context.go('/conversations');
      } else {
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

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    if (_loading) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.local_fire_department, size: 64, color: primary),
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
              Icon(Icons.local_fire_department, size: 80, color: primary),
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
                  child: const Text('Import Existing Key'),
                ),
              ),
              const Spacer(flex: 1),
              // Version info
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text('v0.1.0-alpha', style: TextStyle(color: Color(0xFF5C6B77), fontSize: 11)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
