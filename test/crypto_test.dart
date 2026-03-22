import 'package:flutter_test/flutter_test.dart';
import 'package:inferno/crypto/nostr_key.dart';
import 'package:inferno/crypto/nostr_event.dart';
import 'package:inferno/crypto/nostr_signer.dart';
import 'package:inferno/crypto/nostr_verifier.dart';
import 'package:inferno/crypto/nip44_crypto.dart';
import 'package:inferno/crypto/bech32_nostr.dart';

void main() {
  group('NostrKey', () {
    test('generates valid keypair', () {
      final key = NostrKey.generate();
      expect(key.privateKeyHex.length, 64);
      expect(key.publicKeyHex.length, 64);
    });

    test('derives consistent public key from private key', () {
      final key1 = NostrKey.fromPrivateKey(
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      final key2 = NostrKey.fromPrivateKey(
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      );
      expect(key1.publicKeyHex, key2.publicKeyHex);
    });

    test('hex/bytes roundtrip', () {
      final hex = 'deadbeef01020304';
      final bytes = NostrKey.hexToBytes(hex);
      expect(NostrKey.bytesToHex(bytes), hex);
    });
  });

  group('NostrEvent', () {
    test('computes deterministic event ID', () {
      final event = NostrEvent(
        pubkey: 'a' * 64,
        createdAt: 1234567890,
        kind: 1,
        tags: [],
        content: 'hello world',
      );
      final id1 = event.computeId();
      final id2 = event.computeId();
      expect(id1, id2);
      expect(id1.length, 64);
    });
  });

  group('Sign & Verify', () {
    test('sign and verify a Nostr event', () {
      final key = NostrKey.generate();
      final event = NostrEvent(
        pubkey: key.publicKeyHex,
        createdAt: NostrEvent.now(),
        kind: 1,
        tags: [],
        content: 'test message',
      );

      final signer = NostrSigner(privateKeyHex: key.privateKeyHex);
      final signed = signer.sign(event);

      expect(signed.id, isNotNull);
      expect(signed.sig, isNotNull);
      expect(signed.sig!.length, 128); // 64 bytes hex

      // Verify
      expect(NostrVerifier.verifyEvent(signed), isTrue);
    });

    test('verification fails with wrong pubkey', () {
      final key1 = NostrKey.generate();
      final key2 = NostrKey.generate();

      final event = NostrEvent(
        pubkey: key2.publicKeyHex, // wrong pubkey
        createdAt: NostrEvent.now(),
        kind: 1,
        tags: [],
        content: 'test',
      );

      final signer = NostrSigner(privateKeyHex: key1.privateKeyHex);
      final signed = signer.sign(event);
      // ID is computed from key2's pubkey but signed with key1 — verify should fail
      expect(NostrVerifier.verifyEvent(signed), isFalse);
    });

    test('verification fails with tampered content', () {
      final key = NostrKey.generate();
      final event = NostrEvent(
        pubkey: key.publicKeyHex,
        createdAt: NostrEvent.now(),
        kind: 1,
        tags: [],
        content: 'original',
      );

      final signer = NostrSigner(privateKeyHex: key.privateKeyHex);
      final signed = signer.sign(event);

      // Tamper with content
      final tampered = NostrEvent(
        id: signed.id,
        pubkey: signed.pubkey,
        createdAt: signed.createdAt,
        kind: signed.kind,
        tags: signed.tags,
        content: 'tampered',
        sig: signed.sig,
      );
      expect(NostrVerifier.verifyEvent(tampered), isFalse);
    });
  });

  group('NIP-44', () {
    test('encrypt and decrypt roundtrip', () {
      final alice = NostrKey.generate();
      final bob = NostrKey.generate();

      // Derive conversation keys (should be the same from both sides)
      final aliceConvKey = Nip44Crypto.conversationKey(
        alice.privateKeyHex, bob.publicKeyHex,
      );
      final bobConvKey = Nip44Crypto.conversationKey(
        bob.privateKeyHex, alice.publicKeyHex,
      );

      // Conversation keys must match (ECDH symmetry)
      expect(NostrKey.bytesToHex(aliceConvKey), NostrKey.bytesToHex(bobConvKey));

      // Encrypt with Alice's key, decrypt with Bob's key
      const message = 'Hello from Alice to Bob!';
      final encrypted = Nip44Crypto.encrypt(message, aliceConvKey);
      final decrypted = Nip44Crypto.decrypt(encrypted, bobConvKey);

      expect(decrypted, message);
    });

    test('handles unicode content', () {
      final key1 = NostrKey.generate();
      final key2 = NostrKey.generate();
      final convKey = Nip44Crypto.conversationKey(
        key1.privateKeyHex, key2.publicKeyHex,
      );

      const message = 'Hello 世界! 🔥 Ñoño';
      final encrypted = Nip44Crypto.encrypt(message, convKey);
      final decrypted = Nip44Crypto.decrypt(encrypted, convKey);
      expect(decrypted, message);
    });

    test('wrong key fails to decrypt', () {
      final key1 = NostrKey.generate();
      final key2 = NostrKey.generate();
      final key3 = NostrKey.generate();

      final convKey12 = Nip44Crypto.conversationKey(
        key1.privateKeyHex, key2.publicKeyHex,
      );
      final convKey13 = Nip44Crypto.conversationKey(
        key1.privateKeyHex, key3.publicKeyHex,
      );

      final encrypted = Nip44Crypto.encrypt('secret', convKey12);
      expect(
        () => Nip44Crypto.decrypt(encrypted, convKey13),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Bech32', () {
    test('npub encode/decode roundtrip', () {
      final key = NostrKey.generate();
      final npub = Bech32Nostr.npubEncode(key.publicKeyHex);
      expect(npub.startsWith('npub1'), isTrue);
      final decoded = Bech32Nostr.npubDecode(npub);
      expect(decoded, key.publicKeyHex);
    });

    test('nsec encode/decode roundtrip', () {
      final key = NostrKey.generate();
      final nsec = Bech32Nostr.nsecEncode(key.privateKeyHex);
      expect(nsec.startsWith('nsec1'), isTrue);
      final decoded = Bech32Nostr.nsecDecode(nsec);
      expect(decoded, key.privateKeyHex);
    });

    test('validates npub/nsec/ncryptsec', () {
      final key = NostrKey.generate();
      final npub = Bech32Nostr.npubEncode(key.publicKeyHex);
      final nsec = Bech32Nostr.nsecEncode(key.privateKeyHex);

      expect(Bech32Nostr.isNpub(npub), isTrue);
      expect(Bech32Nostr.isNsec(nsec), isTrue);
      expect(Bech32Nostr.isNpub(nsec), isFalse);
      expect(Bech32Nostr.isNsec(npub), isFalse);
    });
  });
}
