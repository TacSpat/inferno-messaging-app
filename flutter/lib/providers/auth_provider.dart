import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/auth_service.dart';
import '../services/nostr_profile_service.dart';
import '../nostr/relay_pool.dart';

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});

final authStateProvider = FutureProvider<AuthState>((ref) async {
  final authService = ref.watch(authServiceProvider);
  return authService.initialize();
});

final relayPoolProvider = Provider<RelayPool>((ref) {
  final pool = RelayPool();
  ref.onDispose(() => pool.stop());
  return pool;
});

final profileServiceProvider = Provider<NostrProfileService>((ref) {
  final pool = ref.watch(relayPoolProvider);
  return NostrProfileService(pool);
});
