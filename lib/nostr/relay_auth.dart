import '../crypto/nostr_event.dart';
import '../crypto/nostr_signer.dart';

class RelayAuth {
  /// Build a signed NIP-42 AUTH response event
  /// challenge: the challenge string from the relay
  /// relayUrl: the URL of the relay requesting auth
  /// privateKeyHex: our signing key
  /// publicKeyHex: our public key
  static NostrEvent buildAuthEvent({
    required String challenge,
    required String relayUrl,
    required String privateKeyHex,
    required String publicKeyHex,
  }) {
    final event = NostrEvent(
      pubkey: publicKeyHex,
      createdAt: NostrEvent.now(),
      kind: 22242,
      tags: [
        ['relay', relayUrl],
        ['challenge', challenge],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    return signer.sign(event);
  }
}
