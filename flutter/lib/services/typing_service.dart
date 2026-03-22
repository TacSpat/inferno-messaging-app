import 'dart:async';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../nostr/relay_pool.dart';

class TypingService {
  final RelayPool _relayPool;

  // Track who is typing where: channelGroupId -> {pubkey: expiry}
  final Map<String, Map<String, DateTime>> _typingState = {};

  // Debounce our own typing events
  Timer? _typingTimer;
  String? _lastTypingChannel;

  final _typingController = StreamController<TypingUpdate>.broadcast();
  Stream<TypingUpdate> get typingUpdates => _typingController.stream;

  TypingService(this._relayPool);

  /// Send a typing indicator for a channel
  void sendTyping({
    required String privateKeyHex,
    required String publicKeyHex,
    required String channelGroupId,
  }) {
    // Debounce: only send every 3 seconds
    if (_lastTypingChannel == channelGroupId && _typingTimer?.isActive == true) return;
    _lastTypingChannel = channelGroupId;
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {});

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

  /// Process inbound Kind 25050 typing indicator
  void processInboundTyping(nostr.NostrEvent event) {
    final hTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'h').firstOrNull;
    if (hTag == null || hTag.length < 2) return;

    final channelGroupId = hTag[1];
    final pubkey = event.pubkey;
    final expiry = DateTime.now().add(const Duration(seconds: 5));

    _typingState.putIfAbsent(channelGroupId, () => {});
    _typingState[channelGroupId]![pubkey] = expiry;

    _typingController.add(TypingUpdate(
      channelGroupId: channelGroupId,
      typingPubkeys: getTypingUsers(channelGroupId),
    ));

    // Auto-clear after 5 seconds
    Future.delayed(const Duration(seconds: 5), () {
      _typingState[channelGroupId]?.remove(pubkey);
      _typingController.add(TypingUpdate(
        channelGroupId: channelGroupId,
        typingPubkeys: getTypingUsers(channelGroupId),
      ));
    });
  }

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
