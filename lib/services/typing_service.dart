import 'dart:async';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../nostr/relay_pool.dart';

class TypingService {
  final RelayPool _relayPool;

  // Track who is typing where: channelGroupId -> {pubkey: expiry}
  final Map<String, Map<String, DateTime>> _typingState = {};

  // Debounce our own typing events. Keyed by channelGroupId (or the
  // counterparty pubkey for DMs).
  Timer? _typingTimer;
  final Map<String, DateTime> _lastSentByKey = {};

  // Minimum interval between our own typing events on the same key. Raised
  // from 7s so typing consumes less of a relay's rate budget and doesn't
  // crowd out real message sends.
  static const _typingInterval = Duration(seconds: 15);

  // After a real message is sent, block further typing events on that key
  // for this long so the two don't race into a rate limit.
  static const _postSendSuppression = Duration(seconds: 10);

  final _typingController = StreamController<TypingUpdate>.broadcast();
  Stream<TypingUpdate> get typingUpdates => _typingController.stream;

  TypingService(this._relayPool);

  /// Called by senders right before publishing a real message so the next
  /// typing heartbeat doesn't race the message into a relay's rate limit.
  void suppressAfterSend(String key) {
    // Pretend the last typing send happened far enough in the future that
    // the interval gate below blocks new sends for [_postSendSuppression].
    _lastSentByKey[key] = DateTime.now()
        .add(_postSendSuppression)
        .subtract(_typingInterval);
  }

  /// Send a typing indicator for a channel
  void sendTyping({
    required String privateKeyHex,
    required String publicKeyHex,
    required String channelGroupId,
  }) {
    final now = DateTime.now();
    final last = _lastSentByKey[channelGroupId];
    if (last != null && now.difference(last) < _typingInterval) return;
    _lastSentByKey[channelGroupId] = now;
    _typingTimer?.cancel();
    _typingTimer = Timer(_typingInterval, () {});

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 25050,
      tags: [['h', channelGroupId]],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    _relayPool.publish(signed);
  }

  /// Send a typing indicator to a DM counterparty. Uses the same ephemeral
  /// kind 25050 but scopes it with a `p` tag so only the recipient reacts.
  /// We key rate-limit state under a "dm:<pubkey>" prefix so it doesn't
  /// collide with channel typing state.
  void sendDmTyping({
    required String privateKeyHex,
    required String publicKeyHex,
    required String recipientPubkey,
  }) {
    final key = _dmKey(recipientPubkey);
    final now = DateTime.now();
    final last = _lastSentByKey[key];
    if (last != null && now.difference(last) < _typingInterval) return;
    _lastSentByKey[key] = now;

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 25050,
      tags: [['p', recipientPubkey]],
      content: '',
    );
    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    _relayPool.publish(signed);
  }

  /// Process inbound Kind 25050 typing indicator (channel or DM).
  void processInboundTyping(nostr.NostrEvent event, {String? selfPubkey}) {
    // Channel typing carries an `h` (group id) tag; DM typing carries a `p`
    // tag addressed to us.
    final hTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'h').firstOrNull;
    if (hTag != null && hTag.length >= 2) {
      _recordTyping(hTag[1], event.pubkey);
      return;
    }
    if (selfPubkey != null) {
      final pTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'p').firstOrNull;
      if (pTag != null && pTag.length >= 2 && pTag[1] == selfPubkey) {
        // Route DM typing under the sender pubkey so DM UI can watch it.
        _recordTyping(_dmKey(event.pubkey), event.pubkey);
      }
    }
  }

  void _recordTyping(String key, String pubkey) {
    final expiry = DateTime.now().add(const Duration(seconds: 5));
    _typingState.putIfAbsent(key, () => {});
    _typingState[key]![pubkey] = expiry;
    _typingController.add(TypingUpdate(
      channelGroupId: key,
      typingPubkeys: getTypingUsers(key),
    ));
    Future.delayed(const Duration(seconds: 5), () {
      _typingState[key]?.remove(pubkey);
      _typingController.add(TypingUpdate(
        channelGroupId: key,
        typingPubkeys: getTypingUsers(key),
      ));
    });
  }

  String _dmKey(String pubkey) => 'dm:$pubkey';

  /// Watch typing users for a DM counterparty.
  Stream<List<String>> watchDmTyping(String counterpartyPubkey) =>
      watchTyping(_dmKey(counterpartyPubkey));

  /// Get currently typing users for a channel
  List<String> getTypingUsers(String channelGroupId) {
    final now = DateTime.now();
    final users = _typingState[channelGroupId];
    if (users == null) return [];
    users.removeWhere((_, expiry) => expiry.isBefore(now));
    return users.keys.toList();
  }

  /// Stream of typing users for a specific channel
  Stream<List<String>> watchTyping(String channelGroupId) {
    return typingUpdates
        .where((u) => u.channelGroupId == channelGroupId)
        .map((u) => u.typingPubkeys);
  }

  void dispose() {
    _typingTimer?.cancel();
    _typingController.close();
  }
}

class TypingUpdate {
  final String channelGroupId;
  final List<String> typingPubkeys;
  TypingUpdate({required this.channelGroupId, required this.typingPubkeys});
}
