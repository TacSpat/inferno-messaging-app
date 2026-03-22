import 'package:flutter_test/flutter_test.dart';
import 'package:inferno/crypto/nostr_key.dart';
import 'package:inferno/crypto/nip49_crypto.dart';
import 'package:inferno/crypto/bech32_nostr.dart';

void main() {
  group('NIP-49', () {
    test('encrypt and decrypt roundtrip', () {
      final key = NostrKey.generate();
      const password = 'test-password-123';

      // Use logN=8 for fast test (production uses 16)
      final ncryptsec = Nip49Crypto.encrypt(
        key.privateKeyHex, password, logN: 8,
      );

      expect(ncryptsec.startsWith('ncryptsec1'), isTrue);
      expect(Bech32Nostr.isNcryptsec(ncryptsec), isTrue);

      final decrypted = Nip49Crypto.decrypt(ncryptsec, password);
      expect(decrypted, key.privateKeyHex);
    });

    test('wrong password fails', () {
      final key = NostrKey.generate();
      final ncryptsec = Nip49Crypto.encrypt(
        key.privateKeyHex, 'correct', logN: 8,
      );

      expect(
        () => Nip49Crypto.decrypt(ncryptsec, 'wrong'),
        throwsA(anything),
      );
    });
  });
}
