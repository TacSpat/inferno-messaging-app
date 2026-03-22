import 'dart:async';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../nostr/relay_pool.dart';

enum OnlineState { offline, online, idle, dnd, invisible }

extension OnlineStateExtension on OnlineState {
  String get value {
    switch (this) {
      case OnlineState.offline: return 'offline';
      case OnlineState.online: return 'online';
      case OnlineState.idle: return 'idle';
      case OnlineState.dnd: return 'dnd';
      case OnlineState.invisible: return 'invisible';
    }
  }

  static OnlineState fromString(String s) {
    switch (s) {
      case 'online': return OnlineState.online;
      case 'idle': return OnlineState.idle;
      case 'dnd': return OnlineState.dnd;
      case 'invisible': return OnlineState.invisible;
      default: return OnlineState.offline;
    }
  }
}

class PresenceService {
  final RelayPool _relayPool;

  // Track presence: pubkey -> state
  final Map<String, OnlineState> _presenceState = {};
  Timer? _publishTimer;
  OnlineState _currentState = OnlineState.online;

  final _presenceController = StreamController<PresenceUpdate>.broadcast();
  Stream<PresenceUpdate> get presenceUpdates => _presenceController.stream;

  PresenceService(this._relayPool);

  OnlineState get currentState => _currentState;

  /// Set and publish our online state
  Future<void> setPresence({
    required String privateKeyHex,
    required String publicKeyHex,
    required OnlineState state,
  }) async {
    _currentState = state;
    await _publishPresence(privateKeyHex, publicKeyHex, state);
  }

  /// Start periodic presence publishing (every 2 minutes)
  void startPeriodicPublish(String privateKeyHex, String publicKeyHex) {
    _publishTimer?.cancel();
    _publishTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_currentState != OnlineState.invisible) {
        _publishPresence(privateKeyHex, publicKeyHex, _currentState);
      }
    });
    // Publish immediately
    _publishPresence(privateKeyHex, publicKeyHex, _currentState);
  }

  /// Stop periodic publishing and go offline
  Future<void> goOffline(String privateKeyHex, String publicKeyHex) async {
    _publishTimer?.cancel();
    _publishTimer = null;
    _currentState = OnlineState.offline;
    await _publishPresence(privateKeyHex, publicKeyHex, OnlineState.offline);
  }

  /// Process inbound Kind 30315 presence event
  void processInboundPresence(nostr.NostrEvent event) {
    final statusTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'status').firstOrNull;
    if (statusTag == null || statusTag.length < 2) return;

    final state = OnlineStateExtension.fromString(statusTag[1]);
    final oldState = _presenceState[event.pubkey];
    _presenceState[event.pubkey] = state;

    if (oldState != state) {
      _presenceController.add(PresenceUpdate(
        pubkey: event.pubkey,
        state: state,
      ));
    }
  }

  /// Get presence for a pubkey
  OnlineState getPresence(String pubkey) {
    return _presenceState[pubkey] ?? OnlineState.offline;
  }

  /// Watch presence changes for a specific pubkey
  Stream<OnlineState> watchPresence(String pubkey) {
    return presenceUpdates
        .where((u) => u.pubkey == pubkey)
        .map((u) => u.state);
  }

  Future<void> _publishPresence(String privateKeyHex, String publicKeyHex, OnlineState state) async {
    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 30315,
      tags: [
        ['d', 'general'],
        ['status', state.value],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    _relayPool.publish(signed);
  }

  void dispose() {
    _publishTimer?.cancel();
    _presenceController.close();
  }
}

class PresenceUpdate {
  final String pubkey;
  final OnlineState state;
  PresenceUpdate({required this.pubkey, required this.state});
}
