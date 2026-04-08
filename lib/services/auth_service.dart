import 'dart:async';
import '../crypto/nostr_key.dart';
import 'key_management_service.dart';

enum AuthState { unknown, unauthenticated, authenticated }

class AuthService {
  NostrKey? _currentKey;
  AuthState _state = AuthState.unknown;

  NostrKey? get currentKey => _currentKey;
  AuthState get state => _state;
  String? get publicKeyHex => _currentKey?.publicKeyHex;
  String? get privateKeyHex => _currentKey?.privateKeyHex;

  /// Check if a key is stored and load it
  Future<AuthState> initialize() async {
    _currentKey = await KeyManagementService.load();
    _state = _currentKey != null ? AuthState.authenticated : AuthState.unauthenticated;
    return _state;
  }

  /// Create a new account (generate keypair)
  Future<NostrKey> signup() async {
    _currentKey = await KeyManagementService.generateAndStore();
    _state = AuthState.authenticated;
    return _currentKey!;
  }

  /// Import from nsec
  Future<NostrKey> importNsec(String nsec) async {
    _currentKey = await KeyManagementService.importNsec(nsec);
    _state = AuthState.authenticated;
    return _currentKey!;
  }

  /// Import from ncryptsec with password
  Future<NostrKey> importNcryptsec(String ncryptsec, String password) async {
    _currentKey = await KeyManagementService.importNcryptsec(ncryptsec, password);
    _state = AuthState.authenticated;
    return _currentKey!;
  }

  /// Log out (delete stored key)
  Future<void> logout() async {
    await KeyManagementService.deleteKey();
    _currentKey = null;
    _state = AuthState.unauthenticated;
  }
}
