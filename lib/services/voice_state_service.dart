import 'package:drift/drift.dart';
import '../database/database.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../crypto/nip44_crypto.dart';
import '../nostr/relay_pool.dart';
import 'dart:convert';

class VoiceStateService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  VoiceStateService(this._db, this._relayPool);

  /// Join a voice channel (create local voice state)
  Future<VoiceState> joinChannel({
    required int userId,
    required int serverId,
    required int channelId,
  }) async {
    // Remove any existing voice state for this user in this server
    await (_db.delete(_db.voiceStates)
          ..where((v) => v.userId.equals(userId) & v.serverId.equals(serverId)))
        .go();

    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    final sessionId = '${userId}_${now.millisecondsSinceEpoch}';

    final id = await _db.into(_db.voiceStates).insert(VoiceStatesCompanion.insert(
      publicId: publicId,
      userId: userId,
      serverId: serverId,
      channelId: channelId,
      sessionId: sessionId,
      createdAt: now,
      updatedAt: now,
    ));

    return (_db.select(_db.voiceStates)..where((v) => v.id.equals(id))).getSingle();
  }

  /// Leave a voice channel
  Future<void> leaveChannel(int userId, int serverId) async {
    await (_db.delete(_db.voiceStates)
          ..where((v) => v.userId.equals(userId) & v.serverId.equals(serverId)))
        .go();
  }

  /// Update self-mute state
  Future<void> setSelfMute(int voiceStateId, bool muted) async {
    await (_db.update(_db.voiceStates)..where((v) => v.id.equals(voiceStateId)))
        .write(VoiceStatesCompanion(selfMute: Value(muted), updatedAt: Value(DateTime.now())));
  }

  /// Update self-deafen state
  Future<void> setSelfDeaf(int voiceStateId, bool deaf) async {
    await (_db.update(_db.voiceStates)..where((v) => v.id.equals(voiceStateId)))
        .write(VoiceStatesCompanion(
      selfDeaf: Value(deaf),
      selfMute: deaf ? const Value(true) : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Update screen share state
  Future<void> setScreenShare(int voiceStateId, bool sharing) async {
    await (_db.update(_db.voiceStates)..where((v) => v.id.equals(voiceStateId)))
        .write(VoiceStatesCompanion(screenShareOn: Value(sharing), updatedAt: Value(DateTime.now())));
  }

  /// Update video state
  Future<void> setVideo(int voiceStateId, bool videoOn) async {
    await (_db.update(_db.voiceStates)..where((v) => v.id.equals(voiceStateId)))
        .write(VoiceStatesCompanion(videoOn: Value(videoOn), updatedAt: Value(DateTime.now())));
  }

  /// Watch voice states for a channel
  Stream<List<VoiceState>> watchChannelVoiceStates(int channelId) {
    return (_db.select(_db.voiceStates)..where((v) => v.channelId.equals(channelId))).watch();
  }

  /// Watch voice states for a server (all channels)
  Stream<List<VoiceState>> watchServerVoiceStates(int serverId) {
    return (_db.select(_db.voiceStates)..where((v) => v.serverId.equals(serverId))).watch();
  }

  /// Get current voice state for a user in a server
  Future<VoiceState?> getUserVoiceState(int userId, int serverId) {
    return (_db.select(_db.voiceStates)
          ..where((v) => v.userId.equals(userId) & v.serverId.equals(serverId)))
        .getSingleOrNull();
  }

  /// Publish voice state sync to remote instances via encrypted Kind 14 DM
  Future<void> publishVoiceStateSync({
    required String privateKeyHex,
    required String publicKeyHex,
    required String targetPubkey,
    required String action, // "join" or "leave"
    required String serverGroupId,
    required String channelPublicId,
    Map<String, dynamic>? userInfo,
  }) async {
    final payload = json.encode({
      'type': 'voice_state_sync',
      'action': action,
      'server_nostr_group_id': serverGroupId,
      'channel_public_id': channelPublicId,
      if (userInfo != null) ...userInfo,
    });

    final convKey = Nip44Crypto.conversationKey(privateKeyHex, targetPubkey);
    final encrypted = Nip44Crypto.encrypt(payload, convKey);

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 14,
      tags: [['p', targetPubkey]],
      content: encrypted,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
  }
}
