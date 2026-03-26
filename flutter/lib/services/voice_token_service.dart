import 'dart:convert';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../crypto/nip44_crypto.dart';
import '../nostr/relay_pool.dart';

class VoiceTokenService {
  /// Generate a LiveKit JWT token locally (when we are the voice provider)
  static String generateToken({
    required String apiKey,
    required String apiSecret,
    required String roomName,
    required String participantIdentity,
    String? participantName,
    bool canPublish = true,
    bool canSubscribe = true,
    Duration expiry = const Duration(hours: 6),
  }) {
    final now = DateTime.now();
    final claims = {
      'iss': apiKey,
      'sub': participantIdentity,
      'nbf': now.millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(expiry).millisecondsSinceEpoch ~/ 1000,
      'video': {
        'room': roomName,
        'roomJoin': true,
        'canPublish': canPublish,
        'canSubscribe': canSubscribe,
      },
      if (participantName != null) 'name': participantName,
    };

    final jwt = JWT(claims);
    return jwt.sign(SecretKey(apiSecret), algorithm: JWTAlgorithm.HS256);
  }

  /// Build a room name for a server voice channel
  static String roomName(String serverPublicId, String channelPublicId) {
    return 'srv-$serverPublicId-$channelPublicId';
  }

  /// Request a voice token from a remote provider via encrypted Nostr DM
  static Future<void> requestToken({
    required RelayPool relayPool,
    required String privateKeyHex,
    required String publicKeyHex,
    required String providerPubkey,
    required String serverGroupId,
    required String channelPublicId,
    required String requestId,
    String? userDisplayName,
  }) async {
    final payload = json.encode({
      'type': 'voice_token_request',
      'request_id': requestId,
      'server_nostr_group_id': serverGroupId,
      'channel_id': channelPublicId,
      'user_pubkey': publicKeyHex,
      'user_id': publicKeyHex.substring(0, 12),
      'user_display_name': userDisplayName ?? publicKeyHex.substring(0, 8),
    });

    final convKey = Nip44Crypto.conversationKey(privateKeyHex, providerPubkey);
    final encrypted = Nip44Crypto.encrypt(payload, convKey);

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 14,
      tags: [['p', providerPubkey]],
      content: encrypted,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await relayPool.publish(signed);
  }

  /// Build a voice token response (sent by the provider)
  static Future<void> respondWithToken({
    required RelayPool relayPool,
    required String privateKeyHex,
    required String publicKeyHex,
    required String requesterPubkey,
    required String requestId,
    required String token,
    required String livekitUrl,
  }) async {
    final payload = json.encode({
      'type': 'voice_token_response',
      'request_id': requestId,
      'token': token,
      'livekit_url': livekitUrl,
    });

    final convKey = Nip44Crypto.conversationKey(privateKeyHex, requesterPubkey);
    final encrypted = Nip44Crypto.encrypt(payload, convKey);

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 14,
      tags: [['p', requesterPubkey]],
      content: encrypted,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await relayPool.publish(signed);
  }
}
