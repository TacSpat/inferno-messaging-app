import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';

class ServerSyncService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  ServerSyncService(this._db, this._relayPool);

  /// Sync all server state from relays for a given nostr group ID.
  /// Matches Rails NostrServerJoinJob: metadata → structure → roles → members → emojis → stickers → bans → messages
  /// Pre-loaded events from discovery (avoids re-fetching from relay)
  List<nostr.NostrEvent>? preloadedStructure;
  List<nostr.NostrEvent>? preloadedRoles;
  List<nostr.NostrEvent>? preloadedMetadata;

  // Temporary state from metadata parsing
  String? _afkChannelPublicId;
  List<String> _voiceProviderPubkeys = [];

  Future<Server?> syncServer(String nostrGroupId, {void Function(String step, double progress)? onProgress}) async {
    onProgress?.call('Syncing metadata...', 0.1);
    debugPrint('[SyncServer] START nostrGroupId=$nostrGroupId');

    // Check if server already exists in DB — try exact match, then try cleaned version
    var server = await (_db.select(_db.servers)
          ..where((s) => s.nostrGroupId.equals(nostrGroupId)))
        .getSingleOrNull();

    // Also try with cleaned gid (handles double-prefix cases)
    if (server == null) {
      final cleaned = nostrGroupId.replaceAll(RegExp(r'^(inferno-)+'), 'inferno-');
      if (cleaned != nostrGroupId) {
        server = await (_db.select(_db.servers)
              ..where((s) => s.nostrGroupId.equals(cleaned)))
            .getSingleOrNull();
      }
    }

    // Also try with the raw ID (without prefix) as an exact match
    if (server == null) {
      var raw = nostrGroupId;
      while (raw.startsWith('inferno-')) raw = raw.substring(8);
      if (raw.isNotEmpty) {
        // Try "inferno-{raw}" as exact match
        server = await (_db.select(_db.servers)
              ..where((s) => s.nostrGroupId.equals('inferno-$raw')))
            .getSingleOrNull();
      }
    }

    debugPrint('[SyncServer] DB lookup: server=${server?.name ?? "NOT FOUND"} (id=${server?.id})');

    // If not in DB, try to fetch metadata from relays
    // Rails metadata d-tag = "inferno-{nostr_group_id}" where nostr_group_id = "inferno-{public_id}"
    // So the full d-tag is "inferno-inferno-{public_id}" — always prepend "inferno-"
    if (server == null) {
      final dTag = 'inferno-$nostrGroupId';
      debugPrint('[SyncServer] Metadata lookup d-tag: $dTag');
      final metadataEvents = await _fetchOrUse(
        'metadata',
        NostrFilter(kinds: [31750], tags: {'#d': [dTag]}),
        preloaded: preloadedMetadata,
      );

      if (metadataEvents.isNotEmpty) {
        final sorted = metadataEvents.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        server = await _processMetadata(sorted.first, nostrGroupId);
      }
    } else {
      // Server exists — try to update metadata
      final dTag = 'inferno-$nostrGroupId';
      debugPrint('[SyncServer] Metadata update d-tag: $dTag');
      final metadataEvents = await _fetchOrUse(
        'metadata-update',
        NostrFilter(kinds: [31750], tags: {'#d': [dTag]}),
        preloaded: preloadedMetadata,
        timeout: const Duration(seconds: 5),
      );
      if (metadataEvents.isNotEmpty) {
        metadataEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        await _processMetadata(metadataEvents.first, nostrGroupId);
        server = await (_db.select(_db.servers)
              ..where((s) => s.nostrGroupId.equals(nostrGroupId)))
            .getSingleOrNull();
      }
    }

    if (server == null) {
      debugPrint('[SyncServer] FAILED: server is null after all lookups');
      return null;
    }
    debugPrint('[SyncServer] Proceeding with server: ${server.name} (gid=${server.nostrGroupId})');

    // Structure — continue on failure
    onProgress?.call('Syncing channels...', 0.25);
    try {
      await _syncStructure(nostrGroupId, server.id);
      final channelCount = await (_db.select(_db.channels)..where((c) => c.serverId.equals(server!.id))).get();
      debugPrint('[Sync] After structure sync: ${channelCount.length} channels');
    } catch (e) {
      debugPrint('[Sync] Structure sync failed: $e');
    }

    // Resolve AFK channel from metadata tags
    try { await _resolveAfkChannel(server!.id); } catch (_) {}

    // Create voice providers from metadata tags
    try { await _syncVoiceProviders(server!.id); } catch (_) {}

    // Roles — continue on failure
    onProgress?.call('Syncing roles...', 0.4);
    try {
      await _syncRoles(nostrGroupId, server.id);
    } catch (e) {
      debugPrint('[Sync] Roles sync failed: $e');
    }

    // Members — continue on failure
    onProgress?.call('Syncing members...', 0.55);
    try {
      await _syncMembers(nostrGroupId, server.id);
    } catch (e) {
      debugPrint('[Sync] Members sync failed: $e');
    }

    // Emojis + stickers (can fail)
    onProgress?.call('Syncing emojis & stickers...', 0.7);
    await Future.wait([
      _syncEmojis(nostrGroupId, server.id).catchError((_) {}),
      _syncStickers(nostrGroupId, server.id).catchError((_) {}),
    ]);

    // Don't backfill messages during join — only backfill when opening a channel
    // (matches Rails: Thread.new { NostrHistoryFetcher.fetch_channel(channel) } on channel open)

    // Subscribe to live events
    onProgress?.call('Setting up live feed...', 0.9);
    _subscribeToServerChannels(server.id);

    // Clear preloaded events so stale data doesn't persist to next sync
    clearPreloaded();

    onProgress?.call('Done!', 1.0);
    return server;
  }

  /// Process Kind 31750 server metadata
  Future<Server?> _processMetadata(nostr.NostrEvent event, String nostrGroupId) async {
    String? name, description, iconUrl, bannerUrl, afkChannelPublicId;
    final relayUrls = <String>[];
    final voiceProviderPubkeys = <String>[];
    bool discoverable = false;
    bool voiceEnabled = false;

    for (final tag in event.tags) {
      if (tag.isEmpty) continue;
      switch (tag[0]) {
        case 'name': name = tag.length > 1 ? tag[1] : null; break;
        case 'about': description = tag.length > 1 ? tag[1] : null; break;
        case 'picture': iconUrl = tag.length > 1 ? tag[1] : null; break;
        case 'banner': bannerUrl = tag.length > 1 ? tag[1] : null; break;
        case 'owner': break;
        case 'relay': if (tag.length > 1) relayUrls.add(tag[1]); break;
        case 'discoverable': discoverable = tag.length > 1 && tag[1] == 'true'; break;
        case 'voice_enabled': voiceEnabled = tag.length > 1 && tag[1] == 'true'; break;
        case 'afk_channel': afkChannelPublicId = tag.length > 1 ? tag[1] : null; break;
        case 'voice_provider': if (tag.length > 1) voiceProviderPubkeys.add(tag[1]); break;
      }
    }

    if (name == null) return null;
    _afkChannelPublicId = afkChannelPublicId;
    _voiceProviderPubkeys = voiceProviderPubkeys;

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

  /// Fetch from relay using fresh connections, or use pre-loaded events if provided.
  /// Always uses fetchFresh (new throwaway WebSocket per relay) to avoid stale cached data.
  Future<List<nostr.NostrEvent>> _fetchOrUse(String label, NostrFilter filter, {List<nostr.NostrEvent>? preloaded, Duration timeout = const Duration(seconds: 10)}) async {
    if (preloaded != null && preloaded.isNotEmpty) {
      debugPrint('[Sync] $label: using ${preloaded.length} pre-loaded events');
      return preloaded;
    }
    try {
      final events = await _relayPool.fetchFresh(filter, timeout: timeout);
      debugPrint('[Sync] $label: fetched ${events.length} via fresh connections');
      return events;
    } catch (e) {
      debugPrint('[Sync] $label: fetch failed: $e');
      return [];
    }
  }

  /// Clear preloaded events after sync (prevent stale data on next sync)
  void clearPreloaded() {
    preloadedStructure = null;
    preloadedRoles = null;
    preloadedMetadata = null;
  }

  /// Sync Kind 31751 structure (channels + categories)
  Future<void> _syncStructure(String nostrGroupId, int serverId) async {
    // Use nostrGroupId as-is — Rails stores it WITH the inferno- prefix
    // d-tags are: inferno-struct-{gid}, inferno-roles-{gid}, inferno-mbr-{gid}-{pubkey}
    final baseId = nostrGroupId;
    final events = await _fetchOrUse(
      'structure',
      NostrFilter(kinds: [31751], tags: {'#d': ['inferno-struct-$baseId']}),
      preloaded: preloadedStructure,
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latest = events.first;

    // Debug: log all tags from the latest structure event
    final chTags = latest.tags.where((t) => t.isNotEmpty && t[0] == 'ch').toList();
    final catTags = latest.tags.where((t) => t.isNotEmpty && t[0] == 'cat').toList();
    debugPrint('[StructureSync] Latest event has ${chTags.length} ch tags, ${catTags.length} cat tags, ${latest.tags.length} total tags');
    for (final t in chTags) {
      final parentIdx13 = t.length > 13 ? t[13] : '';
      if (parentIdx13.isNotEmpty) {
        debugPrint('[StructureSync]   ${t[2]}: parent=$parentIdx13');
      }
    }

    // Collect parent mappings for second pass
    final parentMappings = <String, String>{}; // channelPublicId → parentChannelPublicId

    // First pass: insert all categories and channels (without parent links)
    for (final tag in latest.tags) {
      if (tag.isEmpty) continue;
      if (tag[0] == 'cat' && tag.length >= 4) {
        // Category: check-then-update-or-insert
        final existingCat = await (_db.select(_db.categories)
              ..where((c) => c.publicId.equals(tag[1])))
            .getSingleOrNull();
        if (existingCat != null) {
          await (_db.update(_db.categories)..where((c) => c.id.equals(existingCat.id)))
              .write(CategoriesCompanion(
            serverId: Value(serverId),
            name: Value(tag[2]),
            position: Value(int.tryParse(tag[3]) ?? 0),
            updatedAt: Value(DateTime.now()),
          ));
        } else {
          await _db.into(_db.categories).insert(
            CategoriesCompanion.insert(
              publicId: tag[1],
              serverId: serverId,
              name: Value(tag[2]),
              position: Value(int.tryParse(tag[3]) ?? 0),
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
        }
      } else if (tag[0] == 'ch' && tag.length >= 5) {
        // Channel: ["ch", publicId, name, channelType, position, categoryPublicId, ...]
        // Skip channels with null/empty type (corrupted data from Rails)
        if (tag[3].isEmpty || tag[3] == 'null' || tag[3] == 'nil') {
          debugPrint('[StructureSync] Skipping channel with nil type: ${tag[2]} (${tag[1]})');
          continue;
        }
        final categoryPublicId = tag.length > 5 ? tag[5] : null;
        int? categoryId;
        if (categoryPublicId != null && categoryPublicId.isNotEmpty) {
          final cat = await (_db.select(_db.categories)
                ..where((c) => c.publicId.equals(categoryPublicId)))
              .getSingleOrNull();
          categoryId = cat?.id;
        }

        final channelNostrGroupId = tag.length > 8 && tag[8].isNotEmpty ? tag[8] : '$nostrGroupId-${tag[1]}';
        final encrypted = tag.length > 10 && tag[10] == 'true';
        final channelPubKey = tag.length > 11 && tag[11].isNotEmpty ? tag[11] : null;
        final parentChannelPublicId = tag.length > 13 && tag[13].isNotEmpty ? tag[13] : null;

        // Defer parent resolution to second pass
        if (parentChannelPublicId != null) {
          parentMappings[tag[1]] = parentChannelPublicId;
        }
        int? parentChannelId; // will be set in second pass

        // Check if channel exists — update if so, insert if not
        final existingChannel = await (_db.select(_db.channels)
              ..where((c) => c.publicId.equals(tag[1])))
            .getSingleOrNull();

        if (existingChannel != null) {
          await (_db.update(_db.channels)..where((c) => c.id.equals(existingChannel.id)))
              .write(ChannelsCompanion(
            serverId: Value(serverId),
            name: Value(tag[2]),
            channelType: Value(_parseChannelType(tag[3])),
            position: Value(int.tryParse(tag[4]) ?? 0),
            categoryId: Value(categoryId),
            parentChannelId: Value(parentChannelId),
            nostrGroupId: Value(channelNostrGroupId),
            encrypted: Value(encrypted),
            channelPublicKey: Value(channelPubKey),
            topic: tag.length > 6 && tag[6].isNotEmpty ? Value(tag[6]) : const Value.absent(),
            nsfw: tag.length > 7 ? Value(tag[7] == 'true') : const Value.absent(),
            updatedAt: Value(DateTime.now()),
          ));
        } else {
          try {
          await _db.into(_db.channels).insert(
          ChannelsCompanion.insert(
            publicId: tag[1],
            serverId: serverId,
            name: tag[2],
            channelType: _parseChannelType(tag[3]),
            position: Value(int.tryParse(tag[4]) ?? 0),
            categoryId: Value(categoryId),
            parentChannelId: Value(parentChannelId),
            nostrGroupId: Value(channelNostrGroupId),
            encrypted: Value(encrypted),
            channelPublicKey: Value(channelPubKey),
            topic: tag.length > 6 && tag[6].isNotEmpty ? Value(tag[6]) : const Value.absent(),
            nsfw: tag.length > 7 ? Value(tag[7] == 'true') : const Value.absent(),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
          debugPrint('[StructureSync] Inserted channel: ${tag[2]} (${tag[1]}) type=${tag[3]} serverId=$serverId');
          } catch (e, st) {
            debugPrint('[StructureSync] FAILED to insert channel ${tag[2]} (${tag[1]}): $e');
            debugPrint('[StructureSync] Tag data: $tag');
          }
        }
      }
    }

    // Second pass: resolve parent channel IDs now that all channels exist
    debugPrint('[StructureSync] Parent mappings: $parentMappings');
    for (final entry in parentMappings.entries) {
      final childPublicId = entry.key;
      final parentPublicId = entry.value;
      final parent = await (_db.select(_db.channels)
            ..where((c) => c.publicId.equals(parentPublicId)))
          .getSingleOrNull();
      if (parent != null) {
        await (_db.update(_db.channels)
              ..where((c) => c.publicId.equals(childPublicId)))
            .write(ChannelsCompanion(parentChannelId: Value(parent.id)));
        debugPrint('[StructureSync] Set parent: $childPublicId -> ${parent.name} (id=${parent.id})');
      } else {
        debugPrint('[StructureSync] Parent NOT FOUND for $childPublicId -> parentPublicId=$parentPublicId');
      }
    }
    // Delete channels/categories not in the latest event (handles deleted channels)
    // Exclude nil-type channels from synced set so they get cleaned up
    final syncedChannelIds = latest.tags
        .where((t) => t.isNotEmpty && t[0] == 'ch' && t.length >= 5
            && t[3] != 'null' && t[3] != 'nil' && t[3].isNotEmpty)
        .map((t) => t[1])
        .toSet();
    final syncedCatIds = latest.tags
        .where((t) => t.isNotEmpty && t[0] == 'cat' && t.length >= 2)
        .map((t) => t[1])
        .toSet();

    final existingChannels = await (_db.select(_db.channels)..where((c) => c.serverId.equals(serverId))).get();
    debugPrint('[StructureSync] Synced publicIds: $syncedChannelIds');
    debugPrint('[StructureSync] Existing channels (serverId=$serverId): ${existingChannels.map((c) => '${c.publicId}(id=${c.id})').toList()}');
    for (final ch in existingChannels) {
      if (!syncedChannelIds.contains(ch.publicId)) {
        debugPrint('[StructureSync] DELETING stale channel: ${ch.name} (${ch.publicId})');
        await (_db.delete(_db.messages)..where((m) => m.channelId.equals(ch.id))).go();
        await (_db.delete(_db.channels)..where((c) => c.id.equals(ch.id))).go();
      }
    }
    final existingCats = await (_db.select(_db.categories)..where((c) => c.serverId.equals(serverId))).get();
    for (final cat in existingCats) {
      if (!syncedCatIds.contains(cat.publicId)) {
        await (_db.delete(_db.categories)..where((c) => c.id.equals(cat.id))).go();
      }
    }

    debugPrint('[StructureSync] Synced ${syncedChannelIds.length} channels, deleted ${existingChannels.length - syncedChannelIds.length} stale, ${parentMappings.length} with parents');
  }

  /// Resolve AFK channel ID from metadata
  Future<void> _resolveAfkChannel(int serverId) async {
    if (_afkChannelPublicId == null || _afkChannelPublicId!.isEmpty) return;
    final afkCh = await (_db.select(_db.channels)
          ..where((c) => c.publicId.equals(_afkChannelPublicId!)))
        .getSingleOrNull();
    if (afkCh != null) {
      await (_db.update(_db.servers)..where((s) => s.id.equals(serverId)))
          .write(ServersCompanion(afkChannelId: Value(afkCh.id)));
      debugPrint('[Sync] Resolved AFK channel: ${afkCh.name} (id=${afkCh.id})');
    }
  }

  /// Create voice provider records from metadata event tags
  Future<void> _syncVoiceProviders(int serverId) async {
    if (_voiceProviderPubkeys.isEmpty) return;
    for (final pubkey in _voiceProviderPubkeys) {
      // Check if provider already exists
      final existing = await (_db.select(_db.serverVoiceProviders)
            ..where((p) => p.serverId.equals(serverId) & p.providerPubkey.equals(pubkey)))
          .getSingleOrNull();
      if (existing != null) continue;

      final now = DateTime.now();
      final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
      try {
        await _db.into(_db.serverVoiceProviders).insert(
          ServerVoiceProvidersCompanion.insert(
            serverId: serverId,
            providerPubkey: Value(pubkey),
            active: const Value(true),
            createdAt: now,
            updatedAt: now,
          ),
        );
        debugPrint('[Sync] Created voice provider: ${pubkey.substring(0, 8)}');
      } catch (_) {}
    }
  }

  /// Sync Kind 31752 roles
  Future<void> _syncRoles(String nostrGroupId, int serverId) async {
    // Use nostrGroupId as-is — Rails stores it WITH the inferno- prefix
    // d-tags are: inferno-struct-{gid}, inferno-roles-{gid}, inferno-mbr-{gid}-{pubkey}
    final baseId = nostrGroupId;
    final events = await _fetchOrUse(
      'roles',
      NostrFilter(kinds: [31752], tags: {'#d': ['inferno-roles-$baseId']}),
      preloaded: preloadedRoles,
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latest = events.first;

    for (final tag in latest.tags) {
      if (tag.isEmpty || tag[0] != 'role' || tag.length < 3) continue;
      // Rails format: ["role", publicId, name, color, position, hoist, mentionable, permissions_json, role_type]
      //                 t[0]    t[1]      t[2]  t[3]   t[4]     t[5]   t[6]         t[7]              t[8]
      final color = tag.length > 3 && tag[3].isNotEmpty ? tag[3] : null;
      final position = tag.length > 4 ? int.tryParse(tag[4]) ?? 0 : 0;
      final permissions = tag.length > 7 && tag[7].isNotEmpty ? tag[7] : null;

      final existingRole = await (_db.select(_db.roles)
            ..where((r) => r.publicId.equals(tag[1])))
          .getSingleOrNull();

      if (existingRole != null) {
        await (_db.update(_db.roles)..where((r) => r.id.equals(existingRole.id)))
            .write(RolesCompanion(
          serverId: Value(serverId),
          name: Value(tag[2]),
          color: Value(color),
          position: Value(position),
          permissions: Value(permissions),
          updatedAt: Value(DateTime.now()),
        ));
      } else {
        try {
          await _db.into(_db.roles).insert(RolesCompanion.insert(
            publicId: tag[1],
            serverId: serverId,
            name: Value(tag[2]),
            color: Value(color),
            position: Value(position),
            permissions: Value(permissions),
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ));
        } catch (_) {} // duplicate
      }
    }
  }

  /// Sync Kind 31754 emojis
  Future<void> _syncEmojis(String nostrGroupId, int serverId) async {
    // Use nostrGroupId as-is — Rails stores it WITH the inferno- prefix
    // d-tags are: inferno-struct-{gid}, inferno-roles-{gid}, inferno-mbr-{gid}-{pubkey}
    final baseId = nostrGroupId;
    final events = await _relayPool.fetchFresh(
      NostrFilter(kinds: [31754], tags: {'#d': ['inferno-emojis-$baseId']}),
      timeout: const Duration(seconds: 10),
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final tag in events.first.tags) {
      if (tag.isEmpty || tag[0] != 'emoji' || tag.length < 3) continue;
      final publicId = tag.length > 3 ? tag[3] : tag[1].hashCode.abs().toRadixString(36).padLeft(12, '0').substring(0, 12);
      try { await _db.into(_db.serverEmojis).insertOnConflictUpdate(
        ServerEmojisCompanion.insert(
          publicId: publicId,
          serverId: serverId,
          name: tag[1],
          creatorId: 0,
          url: Value(tag[2]),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ); } catch (_) {}
    }
  }

  /// Sync Kind 31755 stickers
  Future<void> _syncStickers(String nostrGroupId, int serverId) async {
    // Use nostrGroupId as-is — Rails stores it WITH the inferno- prefix
    // d-tags are: inferno-struct-{gid}, inferno-roles-{gid}, inferno-mbr-{gid}-{pubkey}
    final baseId = nostrGroupId;
    final events = await _relayPool.fetchFresh(
      NostrFilter(kinds: [31755], tags: {'#d': ['inferno-stickers-$baseId']}),
      timeout: const Duration(seconds: 10),
    );
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final tag in events.first.tags) {
      if (tag.isEmpty || tag[0] != 'sticker' || tag.length < 3) continue;
      final publicId = tag.length > 4 ? tag[4] : tag[1].hashCode.abs().toRadixString(36).padLeft(12, '0').substring(0, 12);
      try { await _db.into(_db.serverStickers).insertOnConflictUpdate(
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
      ); } catch (_) {}
    }
  }

  /// Parse channel type from string or int (Rails sends "text"/"voice", not 0/1)
  static int _parseChannelType(String value) {
    switch (value.toLowerCase()) {
      case 'voice': case '1': return 1;
      default: return 0; // text
    }
  }

  /// Fetch server metadata preview (for join screen)
  Future<Map<String, String>?> fetchServerPreview(String nostrGroupId) async {
    final events = await _relayPool.fetchFresh(
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

  /// Sync Kind 31753 members — matches Rails sync_members
  /// Member events use d-tag: "inferno-mbr-{nostrGroupId}-{pubkey[0:16]}"
  /// Rails: nostrGroupId = "inferno-{publicId}", so d-tag = "inferno-mbr-inferno-{publicId}-{16chars}"
  Future<void> _syncMembers(String nostrGroupId, int serverId) async {
    // Use nostrGroupId AS-IS — Rails publishes with "inferno-mbr-{nostrGroupId}-{pubkey}"
    // where nostrGroupId already includes the "inferno-" prefix
    final prefix = 'inferno-mbr-$nostrGroupId-';

    // Try with d-tag filter first (some relays support prefix matching)
    var events = await _fetchOrUse(
      'members',
      NostrFilter(kinds: [31753], tags: {'#d': [prefix]}),
    );

    // If empty, try fetching all kind 31753 and filter locally
    if (events.isEmpty) {
      events = await _relayPool.fetchFresh(
        NostrFilter(kinds: [31753]),
        timeout: const Duration(seconds: 8),
      );
    }

    debugPrint('[MemberSync] nostrGroupId=$nostrGroupId prefix=$prefix totalEvents=${events.length}');

    final memberEvents = events.where((e) {
      final dTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
      return dTag != null && dTag.length > 1 && dTag[1].startsWith(prefix);
    }).toList();

    debugPrint('[MemberSync] After prefix filter: ${memberEvents.length} events match');

    // Group by d-tag and take latest per member
    final grouped = <String, nostr.NostrEvent>{};
    for (final e in memberEvents) {
      final dTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'd').first[1];
      final existing = grouped[dTag];
      if (existing == null || e.createdAt > existing.createdAt) {
        grouped[dTag] = e;
      }
    }

    debugPrint('[MemberSync] Unique members: ${grouped.length}');

    for (final event in grouped.values) {
      // Get member pubkey from p tag
      final pTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'p').firstOrNull;
      if (pTag == null || pTag.length < 2) continue;

      final memberPubkey = pTag[1];
      final removed = event.tags.where((t) => t.isNotEmpty && t[0] == 'removed').firstOrNull;
      if (removed != null && removed.length > 1 && removed[1] == 'true') {
        debugPrint('[MemberSync] Removing member: ${memberPubkey.substring(0, 8)}');
        await (_db.delete(_db.remoteMembers)
              ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(memberPubkey)))
            .go();
        continue;
      }

      await _ensureRemoteMember(serverId, memberPubkey);

      // Assign roles from the member event's "roles" tag (plural)
      // Rails format: ["roles", "publicId1", "publicId2", ...]
      final rolesTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'roles' && t.length >= 2).firstOrNull;
      if (rolesTag != null) {
        final member = await (_db.select(_db.remoteMembers)
              ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(memberPubkey)))
            .getSingleOrNull();
        if (member != null) {
          // Clear old role links for this member (fresh from relay = authoritative)
          await (_db.delete(_db.remoteMembershipRoles)
                ..where((r) => r.remoteMemberId.equals(member.id)))
              .go();
          // Assign each role by publicId
          for (int i = 1; i < rolesTag.length; i++) {
            final rolePublicId = rolesTag[i];
            if (rolePublicId.isEmpty) continue;
            final role = await (_db.select(_db.roles)
                  ..where((r) => r.serverId.equals(serverId) & r.publicId.equals(rolePublicId))
                  ..limit(1))
                .getSingleOrNull();
            if (role != null) {
              try {
                await _db.into(_db.remoteMembershipRoles).insert(
                  RemoteMembershipRolesCompanion.insert(
                    remoteMemberId: member.id, roleId: role.id,
                    createdAt: DateTime.now(), updatedAt: DateTime.now(),
                  ),
                );
              } catch (_) {}
            }
          }
          debugPrint('[MemberSync] Assigned ${rolesTag.length - 1} roles to ${memberPubkey.substring(0, 8)}');
        }
      }

      // Extract embedded profile data from member event tags
      // (Rails embeds profile_name, profile_display_name, profile_picture, etc.)
      String? getTagValue(String key) {
        final t = event.tags.where((t) => t.isNotEmpty && t[0] == key).firstOrNull;
        return (t != null && t.length > 1 && t[1].isNotEmpty) ? t[1] : null;
      }

      final profileName = getTagValue('profile_name');
      final profileDisplayName = getTagValue('profile_display_name');
      final profileAbout = getTagValue('profile_about');
      final profilePicture = getTagValue('profile_picture');
      final profileBanner = getTagValue('profile_banner');
      final profileColor = getTagValue('profile_color');
      final profileStatus = getTagValue('profile_status');
      final profileStatusEmoji = getTagValue('profile_status_emoji');
      final nickname = getTagValue('nickname');
      final joinedAtStr = getTagValue('joined_at');

      // Update remote_member with embedded profile data
      if (profileName != null || profileDisplayName != null || profilePicture != null) {
        await (_db.update(_db.remoteMembers)
              ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(memberPubkey)))
            .write(RemoteMembersCompanion(
          username: profileName != null ? Value(profileName) : const Value.absent(),
          displayName: profileDisplayName != null ? Value(profileDisplayName) : const Value.absent(),
          bio: profileAbout != null ? Value(profileAbout) : const Value.absent(),
          avatarUrl: profilePicture != null ? Value(profilePicture) : const Value.absent(),
          bannerUrl: profileBanner != null ? Value(profileBanner) : const Value.absent(),
          profileColor: profileColor != null ? Value(profileColor) : const Value.absent(),
          status: profileStatus != null ? Value(profileStatus) : const Value.absent(),
          statusEmoji: profileStatusEmoji != null ? Value(profileStatusEmoji) : const Value.absent(),
          nickname: nickname != null ? Value(nickname) : const Value.absent(),
          joinedAt: joinedAtStr != null ? Value(DateTime.fromMillisecondsSinceEpoch(int.tryParse(joinedAtStr) ?? 0 * 1000)) : const Value.absent(),
          updatedAt: Value(DateTime.now()),
        ));
        debugPrint('[MemberSync] Updated profile from member event: ${memberPubkey.substring(0, 8)} name=${profileDisplayName ?? profileName}');
      }

      // Also update contacts table with embedded profile
      if (profileName != null || profileDisplayName != null) {
        await _upsertContact(memberPubkey, {
          'name': profileName,
          'display_name': profileDisplayName,
          'about': profileAbout,
          'picture': profilePicture,
          'banner': profileBanner,
        }, DateTime.now());
      }

      // Queue Kind 0 fetch only if no embedded profile data
      if (profileName == null && profileDisplayName == null) {
        _fetchMemberProfile(memberPubkey);
      }
    }

    // Batch fetch all queued profiles in a single relay request
    await _flushProfileFetches();
  }

  /// Batch fetch profiles for multiple pubkeys in a SINGLE relay request.
  /// Avoids opening separate WebSocket per member (causes rate limiting).
  final Set<String> _pendingProfileFetches = {};

  void _fetchMemberProfile(String pubkey) {
    _pendingProfileFetches.add(pubkey);
  }

  Future<void> _flushProfileFetches() async {
    if (_pendingProfileFetches.isEmpty) return;
    final pubkeys = _pendingProfileFetches.toList();
    _pendingProfileFetches.clear();

    try {
      // Single batch request for all profiles
      final events = await _relayPool.fetchFresh(
        NostrFilter(kinds: [0], authors: pubkeys),
        timeout: const Duration(seconds: 10),
      );
      debugPrint('[ProfileFetch] Batch fetched ${events.length} profiles for ${pubkeys.length} pubkeys');

      // Group by pubkey, take latest per pubkey
      final byPubkey = <String, nostr.NostrEvent>{};
      for (final event in events) {
        final existing = byPubkey[event.pubkey];
        if (existing == null || event.createdAt > existing.createdAt) {
          byPubkey[event.pubkey] = event;
        }
      }

      final now = DateTime.now();
      for (final entry in byPubkey.entries) {
        try {
          final profile = json.decode(entry.value.content) as Map<String, dynamic>;
          await _upsertContact(entry.key, profile, now);
          await (_db.update(_db.remoteMembers)
                ..where((m) => m.pubkey.equals(entry.key)))
              .write(RemoteMembersCompanion(
            username: Value(profile['name'] as String?),
            displayName: Value(profile['display_name'] as String?),
            avatarUrl: Value(profile['picture'] as String?),
            bannerUrl: Value(profile['banner'] as String?),
            bio: Value(profile['about'] as String?),
            nip05: Value(profile['nip05'] as String?),
            profileFetchedAt: Value(now),
            updatedAt: Value(now),
          ));
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[ProfileFetch] Batch fetch failed: $e');
    }
  }

  /// Upsert a contact record (check-then-insert/update to avoid unique constraint issues)
  Future<void> _upsertContact(String pubkey, Map<String, dynamic> profile, DateTime now) async {
    final existing = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (existing != null) {
      await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(pubkey)))
          .write(ContactsCompanion(
        username: Value(profile['name'] as String?),
        displayName: Value(profile['display_name'] as String?),
        bio: Value(profile['about'] as String?),
        avatarUrl: Value(profile['picture'] as String?),
        bannerUrl: Value(profile['banner'] as String?),
        nip05: Value(profile['nip05'] as String?),
        profileFetchedAt: Value(now),
        updatedAt: Value(now),
      ));
    } else {
      try {
        await _db.into(_db.contacts).insert(ContactsCompanion.insert(
          pubkey: pubkey,
          username: Value(profile['name'] as String?),
          displayName: Value(profile['display_name'] as String?),
          bio: Value(profile['about'] as String?),
          avatarUrl: Value(profile['picture'] as String?),
          bannerUrl: Value(profile['banner'] as String?),
          nip05: Value(profile['nip05'] as String?),
          profileFetchedAt: Value(now),
          createdAt: now,
          updatedAt: now,
        ));
      } catch (_) {} // Race condition
    }
  }

  /// Backfill messages for all channels in a server
  Future<void> _backfillAllChannels(int serverId) async {
    final channels = await (_db.select(_db.channels)
          ..where((c) => c.serverId.equals(serverId)))
        .get();
    debugPrint('[Backfill] Backfilling ${channels.length} channels for server $serverId');

    final since = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;

    for (final channel in channels) {
      if (channel.nostrGroupId == null) continue;
      try {
        final events = await _relayPool.fetchFresh(
          NostrFilter(
            kinds: [9, 9005, 9006],
            tags: {'#h': [channel.nostrGroupId!]},
            since: since,
          ),
          timeout: const Duration(seconds: 10),
        );

        // Sort chronologically
        final sorted = events.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

        for (final event in sorted) {
          if (event.kind == 9) {
            // Check dedup
            if (event.id != null) {
              final existing = await (_db.select(_db.messages)
                    ..where((m) => m.nostrEventId.equals(event.id!)))
                  .getSingleOrNull();
              if (existing != null) continue;
            }

            final content = event.content;
            final publicId = event.id != null
                ? event.id!.substring(0, 12)
                : DateTime.now().microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
            final eventTime = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);

            await _db.into(_db.messages).insert(
              MessagesCompanion.insert(
                publicId: publicId,
                content: Value(content),
                channelId: Value(channel.id),
                nostrAuthorPubkey: Value(event.pubkey),
                nostrEventId: Value(event.id),
                nostrEventJson: Value(json.encode(event.toJson())),
                createdAt: eventTime,
                updatedAt: DateTime.now(),
              ),
            );

            // Auto-create remote member if unknown
            _ensureRemoteMember(channel.serverId, event.pubkey);
          } else if (event.kind == 9005) {
            final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
            if (eTag != null && eTag.length > 1) {
              await (_db.delete(_db.messages)..where((m) => m.nostrEventId.equals(eTag[1]))).go();
            }
          } else if (event.kind == 9006) {
            // Pin/unpin
            final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
            final pinnedTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'pinned').firstOrNull;
            if (eTag != null && eTag.length > 1) {
              final pinned = pinnedTag != null && pinnedTag.length > 1 && pinnedTag[1] == 'true';
              await (_db.update(_db.messages)..where((m) => m.nostrEventId.equals(eTag[1])))
                  .write(MessagesCompanion(pinned: Value(pinned), updatedAt: Value(DateTime.now())));
            }
          }
        }
      } catch (_) {
        // Continue with next channel on failure
      }
    }
  }

  /// Ensure a remote member exists for a pubkey in a server.
  /// Uses find-or-create pattern matching Rails: server.remote_members.find_or_initialize_by(pubkey:)
  Future<void> _ensureRemoteMember(int serverId, String pubkey) async {
    final existing = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (existing != null) return;

    final now = DateTime.now();
    final publicId = '${serverId.toRadixString(36)}${pubkey.substring(0, 8)}'.padLeft(12, '0').substring(0, 12);
    try {
      await _db.into(_db.remoteMembers).insert(
        RemoteMembersCompanion.insert(
          publicId: Value(publicId),
          serverId: serverId,
          pubkey: pubkey,
          createdAt: now,
          updatedAt: now,
        ),
      );
    } catch (_) {
      // Race condition — another coroutine inserted first
    }

    // Fetch profile in background (only if not recently fetched)
    final member = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (member != null && (member.profileFetchedAt == null ||
        now.difference(member.profileFetchedAt!).inHours > 1)) {
      _fetchMemberProfile(pubkey);
    }
  }

  /// Subscribe to live events for newly synced server channels
  void _subscribeToServerChannels(int serverId) async {
    final channels = await (_db.select(_db.channels)
          ..where((c) => c.serverId.equals(serverId)))
        .get();
    final groupIds = channels
        .where((c) => c.nostrGroupId != null)
        .map((c) => c.nostrGroupId!)
        .toList();
    if (groupIds.isEmpty) return;

    final since = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch ~/ 1000;
    _relayPool.subscribe(filters: [
      NostrFilter(kinds: [9, 9005, 9006, 7, 25050], tags: {'#h': groupIds}, since: since),
    ]);
  }
}
