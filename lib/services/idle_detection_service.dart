import 'dart:async';
import 'presence_service.dart';

class IdleDetectionService {
  final PresenceService _presenceService;
  final Duration idleTimeout;

  Timer? _idleTimer;
  bool _isIdle = false;
  String? _privateKeyHex;
  String? _publicKeyHex;

  IdleDetectionService(
    this._presenceService, {
    this.idleTimeout = const Duration(minutes: 5),
  });

  /// Start monitoring for idle state
  void start(String privateKeyHex, String publicKeyHex) {
    _privateKeyHex = privateKeyHex;
    _publicKeyHex = publicKeyHex;
    _resetTimer();
  }

  /// Call on any user interaction (tap, key press, mouse move)
  void onActivity() {
    if (_isIdle && _privateKeyHex != null && _publicKeyHex != null) {
      _isIdle = false;
      // Only go back to online if we were auto-idled (not manual DnD/invisible)
      final current = _presenceService.currentState;
      if (current == OnlineState.idle) {
        _presenceService.setPresence(
          privateKeyHex: _privateKeyHex!,
          publicKeyHex: _publicKeyHex!,
          state: OnlineState.online,
        );
      }
    }
    _resetTimer();
  }

  void _resetTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, _onIdle);
  }

  void _onIdle() {
    if (_privateKeyHex == null || _publicKeyHex == null) return;
    final current = _presenceService.currentState;
    // Only auto-idle if currently online (respect manual DnD/invisible)
    if (current == OnlineState.online) {
      _isIdle = true;
      _presenceService.setPresence(
        privateKeyHex: _privateKeyHex!,
        publicKeyHex: _publicKeyHex!,
        state: OnlineState.idle,
      );
    }
  }

  void stop() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void dispose() {
    stop();
  }
}
