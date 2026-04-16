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
import '../../widgets/inferno_logo.dart';
import '../../providers/app_update_provider.dart';

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
      body: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Colors.grey[900]),

          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 36),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Theme.of(context).scaffoldBackgroundColor),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const InfernoLogo(size: 72),
                      const SizedBox(height: 16),
                      Text(
                        'Inferno',
                        style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: primary,
                          fontFamilyFallback: [],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Encrypted · Decentralized · Yours',
                        style: TextStyle(
                          color: primary.withValues(alpha: 0.80),
                          fontSize: 14,
                          letterSpacing: 0.5,
                          fontFamilyFallback: [],
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 20),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF3A1A1A),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFFF4D4D), fontSize: 12, fontFamilyFallback: []),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
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
                        child: ElevatedButton(
                          onPressed: () => context.go('/auth/import'),
                          style: ElevatedButton.styleFrom(
                            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          child: const Text('Import Existing Identity'),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Use an encrypted backup (ncryptsec) from another Nostr client',
                        style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 12, fontFamilyFallback: []),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      Consumer(builder: (context, ref, _) {
                        final version = ref.watch(appVersionProvider);
                        return Text(
                          version.when(data: (v) => 'v$v', loading: () => '', error: (_, __) => ''),
                          style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 11, fontFamilyFallback: []),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
