import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A stable, random identifier for this installation.
///
/// The Nostr pubkey identifies the *user*, and is by design identical on every
/// device they sign in on. Anything that needs to tell one of a user's devices
/// apart from another — voice state, presence, "you are already connected
/// elsewhere" — needs a second identifier, which is this.
///
/// Deliberately random rather than derived from hardware: it must not be a
/// fingerprint, and it must survive a hostname or hardware change. It is
/// published inside voice state payloads, so it is public; it carries no
/// information beyond "same install or not".
class DeviceId {
  static const _key = 'inferno_device_id';
  static const _storage = FlutterSecureStorage();
  static String? _cached;

  /// Returns the device id, creating and persisting one on first call.
  static Future<String> get() async {
    final cached = _cached;
    if (cached != null) return cached;

    final stored = await _storage.read(key: _key);
    if (stored != null && stored.isNotEmpty) {
      _cached = stored;
      return stored;
    }

    final rnd = Random.secure();
    final generated = List.generate(
      8,
      (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _storage.write(key: _key, value: generated);
    _cached = generated;
    return generated;
  }

  /// Non-async accessor for code paths that cannot await. Returns null until
  /// [get] has been called at least once this session.
  static String? get cached => _cached;
}
