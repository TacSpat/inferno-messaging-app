import 'dart:convert';
import 'package:drift/drift.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';

class ServerSyncService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  ServerSyncService(this._db, this._relayPool);

  /// Sync all server state from relays for a given nostr group ID
  Future<Server?> syncServer(String nostrGroupId) async {
    // Fetch metadata (Kind 31750)
    final metadataEvents = await _relayPool.fetch(
      NostrFilter(kinds: [31750], tags: {'#d': ['inferno-$nostrGroupId']}),
      timeout: const Duration(seconds: 10),
    );
    if (metadataEvents.isEmpty) return null;

    metadataEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final metadata = metadataEvents.first;
    final server = await _processMetadata(metadata, nostrGroupId);
    if (server == null) return null;

    // Fetch structure, roles, emojis, stickers in parallel
    await Future.wait([
      _syncStructure(nostrGroupId, server.id),
      _syncRoles(nostrGroupId, server.id),
      _syncEmojis(nostrGroupId, server.id),
      _syncStickers(nostrGroupId, server.id),
    ]);

    return server;
  }

  /// Process Kind 31750 server metadata
  Future<Server?> _processMetadata(nostr.NostrEvent event, String nostrGroupId) async {
    String? name, description, iconUrl, bannerUrl;
    final relayUrls = <String>[];
    bool discoverable = false;
    bool voiceEnabled = false;

    for (final tag in event.tags) {
      if (tag.isEmpty) continue;
      switch (tag[0]) {
        case 'name': name = tag.length > 1 ? tag[1] : null; break;
        case 'about': description = tag.length > 1 ? tag[1] : null; break;
        case 'picture': iconUrl = tag.length > 1 ? tag[1] : null; break;
        case 'banner': bannerUrl = tag.length > 1 ? tag[1] : null; break;
        case 'owner': break; // owner pubkey tracked via server owner
        case 'relay': if (tag.length > 1) relayUrls.add(tag[1]); break;
        case 'discoverable': discoverable = tag.length > 1 && tag[1] == 'true'; break;
        case 'voice_enabled': voiceEnabled = tag.length > 1 && tag[1] == 'true'; break;
      }
    }

    if (name == null) return null;

    final now = DateTime.now();
    // Check if server already exists
    final existing = await (_db.select(_db.servers)
          ..where((s) => s.nostrGroupId.equals(nostrGroupId)))
        .getSingleOrNull();

    final publicId = nostrGroupId.length >= 12
        ? nostrGroupId.substring(0, 12)
        : nostrGroupId.padRight(12, '0');

    if (existing != null) {
      await (_db.update(_db.servers)..where((s) => s.id.equals(existing.id)))
          .write(ServersCompanion(
        name: Value(name),
        description: Value(description),
        iconUrl: Value(iconUrl),
        bannerUrl: Value(bannerUrl),
        relayUrls: Value(json.encode(relayUrls)),
        discoverable: Value(discoverable),
        voiceEnabled: Value(voiceEnabled),
        lastSyncedAt: Value(now),
        updatedAt: Value(now),
      ));
      return (_db.select(_db.servers)..where((s) => s.id.equals(existing.id))).getSingle();
    } else {
      // Need an owner — use first user or create placeholder
      final users = await _db.select(_db.users).get();
      final ownerId = users.isNotEmpty ? users.first.id : 1;

      final id = await _db.into(_db.servers).insert(ServersCompanion.insert(
        publicId: publicId,
        ownerId: ownerId,
        name: name,
        description: Value(description),
        nostrGroupId: Value(nostrGroupId),
        iconUrl: Value(iconUrl),
        bannerUrl: Value(bannerUrl),
        relayUrls: Value(json.encode(relayUrls)),
        discoverable: Value(discoverable),
        voiceEnabled: Value(voiceEnabled),
        lastSyncedAt: Value(now),
        createdAt: now,
        updatedAt: now,
      ));
      return (_db.select(_db.servers)..where((s) => s.id.equals(id))).getSingle();
    }
  }

  /// Sync Kind 31751 structure (channels + categories)
  Future<void> _syncStructure(String nostrGroupId, int serverId) async {
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31751], tags: {'#d': ['inferno-struct-$nostrGroupId']}),
      timeout: const Duration(seconds: 10),
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latest = events.first;

    for (final tag in latest.tags) {
      if (tag.isEmpty) continue;
      if (tag[0] == 'cat' && tag.length >= 4) {
        // Category: ["cat", publicId, name, position]
        await _db.into(_db.categories).insertOnConflictUpdate(
          CategoriesCompanion.insert(
            publicId: tag[1],
            serverId: serverId,
            name: Value(tag[2]),
            position: Value(int.tryParse(tag[3]) ?? 0),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
      } else if (tag[0] == 'ch' && tag.length >= 5) {
        // Channel: ["ch", publicId, name, channelType, position, categoryPublicId, ...]
        final categoryPublicId = tag.length > 5 ? tag[5] : null;
        int? categoryId;
        if (categoryPublicId != null && categoryPublicId.isNotEmpty) {
          final cat = await (_db.select(_db.categories)
                ..where((c) => c.publicId.equals(categoryPublicId)))
              .getSingleOrNull();
          categoryId = cat?.id;
        }

        final channelNostrGroupId = tag.length > 8 ? tag[8] : '$nostrGroupId-${tag[1]}';
        final encrypted = tag.length > 10 && tag[10] == 'true';
        final channelPubKey = tag.length > 11 ? tag[11] : null;

        await _db.into(_db.channels).insertOnConflictUpdate(
          ChannelsCompanion.insert(
            publicId: tag[1],
            serverId: serverId,
            name: tag[2],
            channelType: int.tryParse(tag[3]) ?? 0,
            position: Value(int.tryParse(tag[4]) ?? 0),
            categoryId: Value(categoryId),
            nostrGroupId: Value(channelNostrGroupId),
            encrypted: Value(encrypted),
            channelPublicKey: Value(channelPubKey),
            topic: tag.length > 6 ? Value(tag[6]) : const Value.absent(),
            nsfw: tag.length > 7 ? Value(tag[7] == 'true') : const Value.absent(),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
      }
    }
  }

  /// Sync Kind 31752 roles
  Future<void> _syncRoles(String nostrGroupId, int serverId) async {
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31752], tags: {'#d': ['inferno-roles-$nostrGroupId']}),
      timeout: const Duration(seconds: 10),
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latest = events.first;

    for (final tag in latest.tags) {
      if (tag.isEmpty || tag[0] != 'role' || tag.length < 4) continue;
      // ["role", publicId, name, position, color, permissions_json, ...]
      await _db.into(_db.roles).insertOnConflictUpdate(
        RolesCompanion.insert(
          publicId: tag[1],
          serverId: serverId,
          name: Value(tag[2]),
          position: Value(int.tryParse(tag[3]) ?? 0),
          color: tag.length > 4 ? Value(tag[4]) : const Value.absent(),
          permissions: tag.length > 5 ? Value(tag[5]) : const Value.absent(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Sync Kind 31754 emojis
  Future<void> _syncEmojis(String nostrGroupId, int serverId) async {
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31754], tags: {'#d': ['inferno-emojis-$nostrGroupId']}),
      timeout: const Duration(seconds: 10),
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final tag in events.first.tags) {
      if (tag.isEmpty || tag[0] != 'emoji' || tag.length < 3) continue;
      final publicId = tag.length > 3 ? tag[3] : tag[1].hashCode.abs().toRadixString(36).padLeft(12, '0').substring(0, 12);
      await _db.into(_db.serverEmojis).insertOnConflictUpdate(
        ServerEmojisCompanion.insert(
          publicId: publicId,
          serverId: serverId,
          name: tag[1],
          creatorId: 0,
          url: Value(tag[2]),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Sync Kind 31755 stickers
  Future<void> _syncStickers(String nostrGroupId, int serverId) async {
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31755], tags: {'#d': ['inferno-stickers-$nostrGroupId']}),
      timeout: const Duration(seconds: 10),
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final tag in events.first.tags) {
      if (tag.isEmpty || tag[0] != 'sticker' || tag.length < 3) continue;
      final publicId = tag.length > 4 ? tag[4] : tag[1].hashCode.abs().toRadixString(36).padLeft(12, '0').substring(0, 12);
      await _db.into(_db.serverStickers).insertOnConflictUpdate(
        ServerStickersCompanion.insert(
          publicId: publicId,
          serverId: serverId,
          name: tag[1],
          creatorId: 0,
          url: Value(tag[2]),
          description: tag.length > 3 ? Value(tag[3]) : const Value.absent(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Fetch server metadata preview (for join screen)
  Future<Map<String, String>?> fetchServerPreview(String nostrGroupId) async {
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31750], tags: {'#d': ['inferno-$nostrGroupId']}),
      timeout: const Duration(seconds: 8),
    );
    if (events.isEmpty) return null;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final result = <String, String>{};
    for (final tag in events.first.tags) {
      if (tag.length >= 2) result[tag[0]] = tag[1];
    }
    return result;
  }
}
