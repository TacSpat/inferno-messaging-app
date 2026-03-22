import 'dart:math';
import 'package:drift/drift.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';
import 'server_sync_service.dart';

class InviteService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  InviteService(this._db, this._relayPool);

  /// Generate a new invite code
  String _generateCode() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(8, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// Create an invite for a server
  Future<Invite> createInvite({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
    required int creatorId,
    int? maxUses,
    DateTime? expiresAt,
  }) async {
    final code = _generateCode();
    final now = DateTime.now();

    final id = await _db.into(_db.invites).insert(InvitesCompanion.insert(
      serverId: server.id,
      creatorId: creatorId,
      code: code,
      maxUses: Value(maxUses),
      expiresAt: Value(expiresAt),
      createdAt: now,
      updatedAt: now,
    ));

    // Publish Kind 31757 invite event
    final gid = server.nostrGroupId ?? '';
    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31757,
      tags: [
        ['d', 'inferno-invite-$gid-$code'],
        ['code', code],
        ['server', gid],
        if (maxUses != null) ['max_uses', maxUses.toString()],
        if (expiresAt != null) ['expires', (expiresAt.millisecondsSinceEpoch ~/ 1000).toString()],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);

    return (_db.select(_db.invites)..where((i) => i.id.equals(id))).getSingle();
  }

  /// Resolve an invite code to server info
  Future<Map<String, String>?> resolveInvite(String code) async {
    // Check local DB first
    final local = await (_db.select(_db.invites)
          ..where((i) => i.code.equals(code) & i.active.equals(true)))
        .getSingleOrNull();
    if (local != null) {
      final server = await (_db.select(_db.servers)
            ..where((s) => s.id.equals(local.serverId)))
          .getSingleOrNull();
      if (server != null) {
        return {'name': server.name, 'nostr_group_id': server.nostrGroupId ?? ''};
      }
    }

    // Search relays for the invite event
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31757], tags: {'#d': [code]}),
      timeout: const Duration(seconds: 8),
    );
    if (events.isEmpty) return null;

    for (final event in events) {
      final serverTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'server').firstOrNull;
      if (serverTag != null && serverTag.length > 1) {
        return {'nostr_group_id': serverTag[1], 'code': code};
      }
    }
    return null;
  }

  /// Accept an invite — join the server
  Future<Server?> acceptInvite({
    required String nostrGroupId,
    required int userId,
    required ServerSyncService syncService,
  }) async {
    // Sync server from relays
    final server = await syncService.syncServer(nostrGroupId);
    if (server == null) return null;

    // Create membership
    final publicId = DateTime.now().millisecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
    await _db.into(_db.serverMemberships).insert(
      ServerMembershipsCompanion.insert(
        publicId: publicId,
        userId: userId,
        serverId: server.id,
        joinedAt: Value(DateTime.now()),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    return server;
  }
}
