import 'dart:async';
import 'package:drift/drift.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
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
  InfernoDatabase? _db;

  // Track presence: pubkey -> state
  final Map<String, OnlineState> _presenceState = {};
  final Map<String, DateTime> _lastSeenAt = {};
  Timer? _publishTimer;
  OnlineState _currentState = OnlineState.online;

  final _presenceController = StreamController<PresenceUpdate>.broadcast();
  PresenceUpdate? _lastUpdate;

  /// Presence updates, replaying the most recent one to each new subscriber.
  ///
  /// A plain broadcast stream drops everything emitted before a listener
  /// attaches. Our own transition to online is emitted exactly once, during
  /// startPeriodicPublish(), so a widget that first built before that ran
  /// never learned about it and stayed pinned to the default (offline) for
  /// the rest of the session.
  Stream<PresenceUpdate> get presenceUpdates async* {
    final seed = _lastUpdate;
    if (seed != null) yield seed;
    yield* _presenceController.stream;
  }

  void _emit(PresenceUpdate update) {
    _lastUpdate = update;
    _presenceController.add(update);
  }

  PresenceService(this._relayPool);

  /// Set the database reference for persisting presence to remote_members
  void setDatabase(InfernoDatabase db) {
    _db = db;
  }

  OnlineState get currentState => _currentState;

  /// Set and publish our online state
  Future<void> setPresence({
    required String privateKeyHex,
    required String publicKeyHex,
    required OnlineState state,
  }) async {
    _currentState = state;
    // Update our own presence in the tracking map so getPresence() works for local user
    _presenceState[publicKeyHex] = state;
    _lastSeenAt[publicKeyHex] = DateTime.now();
    _emit(PresenceUpdate(pubkey: publicKeyHex, state: state));
    _persistPresence(publicKeyHex, state);
    await _publishPresence(privateKeyHex, publicKeyHex, state);
  }

  /// Start periodic presence publishing (every 2 minutes)
  void startPeriodicPublish(String privateKeyHex, String publicKeyHex) {
    _publishTimer?.cancel();
    // Set local state immediately so UI shows online right away
    _currentState = OnlineState.online;
    _presenceState[publicKeyHex] = OnlineState.online;
    _lastSeenAt[publicKeyHex] = DateTime.now();
    _emit(PresenceUpdate(pubkey: publicKeyHex, state: OnlineState.online));
    _persistPresence(publicKeyHex, OnlineState.online);

    _publishTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_currentState != OnlineState.invisible) {
        _presenceState[publicKeyHex] = _currentState;
        _lastSeenAt[publicKeyHex] = DateTime.now();
        // Re-emit so the UI keeps reflecting our own state. Without this the
        // republish updated the map silently and nothing ever rebuilt.
        _emit(PresenceUpdate(pubkey: publicKeyHex, state: _currentState));
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

  /// Process inbound Kind 30315 presence event.
  void processInboundPresence(nostr.NostrEvent event) {
    final statusTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'status').firstOrNull;
    // Also try content as fallback (Rails: status_value = event["tags"]...|| event["content"])
    final statusValue = (statusTag != null && statusTag.length >= 2) ? statusTag[1] : event.content;
    if (statusValue.isEmpty) return;

    final state = OnlineStateExtension.fromString(statusValue);

    // Stale detection: ignore "online" events older than 5 minutes (matches Rails PRESENCE_STALE_AFTER)
    final eventAge = DateTime.now().millisecondsSinceEpoch ~/ 1000 - event.createdAt;
    if (state == OnlineState.online && eventAge > 300) {
      // Treat stale "online" as offline
      _presenceState[event.pubkey] = OnlineState.offline;
      return;
    }

    final oldState = _presenceState[event.pubkey];
    _presenceState[event.pubkey] = state;
    _lastSeenAt[event.pubkey] = DateTime.now();

    if (oldState != state) {
      _emit(PresenceUpdate(
        pubkey: event.pubkey,
        state: state,
      ));

      // Persist to remote_members table so it survives widget rebuilds
      _persistPresence(event.pubkey, state);
    }
  }

  /// Persist presence state to the remote_members table
  Future<void> _persistPresence(String pubkey, OnlineState state) async {
    if (_db == null) return;
    try {
      // online_state is an int column: 0=offline, 1=online, 2=idle, 3=dnd, 4=invisible
      final stateInt = state.index;
      await (_db!.update(_db!.remoteMembers)
            ..where((m) => m.pubkey.equals(pubkey)))
          .write(RemoteMembersCompanion(
        onlineState: Value(stateInt),
        lastSeenAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ));
    } catch (_) {
      // Ignore — member may not exist in this server
    }
  }

  /// Get presence for a pubkey.
  /// Returns offline if last seen more than 5 minutes ago (matches Rails PRESENCE_STALE_AFTER).
  OnlineState getPresence(String pubkey) {
    final state = _presenceState[pubkey] ?? OnlineState.offline;
    if (state == OnlineState.online || state == OnlineState.idle) {
      final lastSeen = _lastSeenAt[pubkey];
      if (lastSeen != null && DateTime.now().difference(lastSeen).inMinutes > 5) {
        return OnlineState.offline; // Stale — effectively offline
      }
    }
    return state;
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
