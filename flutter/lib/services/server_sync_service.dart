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
  Future<Server?> syncServer(String nostrGroupId, {void Function(String step, double progress)? onProgress}) async {
    onProgress?.call('Syncing metadata...', 0.1);

    // Check if server already exists in DB (may have been created from discovery data)
    var server = await (_db.select(_db.servers)
          ..where((s) => s.nostrGroupId.equals(nostrGroupId)))
        .getSingleOrNull();

    // If not in DB, try to fetch metadata from relays
    if (server == null) {
      final dTag = nostrGroupId.startsWith('inferno-') ? nostrGroupId : 'inferno-$nostrGroupId';
      final metadataEvents = await _relayPool.fetch(
        NostrFilter(kinds: [31750], tags: {'#d': [dTag]}),
        timeout: const Duration(seconds: 10),
      );

      if (metadataEvents.isNotEmpty) {
        metadataEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        server = await _processMetadata(metadataEvents.first, nostrGroupId);
      }
    } else {
      // Server exists — try to update metadata from relay (may return empty if already fetched)
      final dTag = nostrGroupId.startsWith('inferno-') ? nostrGroupId : 'inferno-$nostrGroupId';
      final metadataEvents = await _relayPool.fetch(
        NostrFilter(kinds: [31750], tags: {'#d': [dTag]}),
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

    if (server == null) return null;

    // Structure
    onProgress?.call('Syncing channels...', 0.25);
    await _syncStructure(nostrGroupId, server.id);

    // Roles
    onProgress?.call('Syncing roles...', 0.4);
    await _syncRoles(nostrGroupId, server.id);

    // Members
    onProgress?.call('Syncing members...', 0.55);
    await _syncMembers(nostrGroupId, server.id);

    // Emojis + stickers (can fail)
    onProgress?.call('Syncing emojis & stickers...', 0.7);
    await Future.wait([
      _syncEmojis(nostrGroupId, server.id).catchError((_) {}),
      _syncStickers(nostrGroupId, server.id).catchError((_) {}),
    ]);

    // Backfill messages
    onProgress?.call('Loading message history...', 0.8);
    await _backfillAllChannels(server.id);

    // Subscribe to live events
    onProgress?.call('Setting up live feed...', 0.95);
    _subscribeToServerChannels(server.id);

    onProgress?.call('Done!', 1.0);
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
    final baseId = nostrGroupId.startsWith('inferno-') ? nostrGroupId.substring(8) : nostrGroupId;
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31751], tags: {'#d': ['inferno-struct-$baseId']}),
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

        final channelNostrGroupId = tag.length > 8 && tag[8].isNotEmpty ? tag[8] : '$nostrGroupId-${tag[1]}';
        final encrypted = tag.length > 10 && tag[10] == 'true';
        final channelPubKey = tag.length > 11 && tag[11].isNotEmpty ? tag[11] : null;
        final parentChannelPublicId = tag.length > 13 && tag[13].isNotEmpty ? tag[13] : null;

        // Resolve parent channel ID for voice nesting
        int? parentChannelId;
        if (parentChannelPublicId != null) {
          final parent = await (_db.select(_db.channels)
                ..where((c) => c.publicId.equals(parentChannelPublicId)))
              .getSingleOrNull();
          parentChannelId = parent?.id;
        }

        // Check if channel exists — update if so, insert if not
        final existingChannel = await (_db.select(_db.channels)
              ..where((c) => c.publicId.equals(tag[1])))
            .getSingleOrNull();

        if (existingChannel != null) {
          await (_db.update(_db.channels)..where((c) => c.id.equals(existingChannel.id)))
              .write(ChannelsCompanion(
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
        }
      }
    }
  }

  /// Sync Kind 31752 roles
  Future<void> _syncRoles(String nostrGroupId, int serverId) async {
    final baseId = nostrGroupId.startsWith('inferno-') ? nostrGroupId.substring(8) : nostrGroupId;
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31752], tags: {'#d': ['inferno-roles-$baseId']}),
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
    final baseId = nostrGroupId.startsWith('inferno-') ? nostrGroupId.substring(8) : nostrGroupId;
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31754], tags: {'#d': ['inferno-emojis-$baseId']}),
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
    final baseId = nostrGroupId.startsWith('inferno-') ? nostrGroupId.substring(8) : nostrGroupId;
    final events = await _relayPool.fetch(
      NostrFilter(kinds: [31755], tags: {'#d': ['inferno-stickers-$baseId']}),
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

  /// Parse channel type from string or int (Rails sends "text"/"voice", not 0/1)
  static int _parseChannelType(String value) {
    switch (value.toLowerCase()) {
      case 'voice': case '1': return 1;
      default: return 0; // text
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

  /// Sync Kind 31753 members — matches Rails sync_members
  /// Member events use d-tag: "inferno-mbr-{gid}-{pubkey}"
  Future<void> _syncMembers(String nostrGroupId, int serverId) async {
    // Try fetching member events with a d-tag prefix search
    final baseId = nostrGroupId.startsWith('inferno-') ? nostrGroupId.substring(8) : nostrGroupId;
    final prefix = 'inferno-mbr-$baseId-';

    // Try with d-tag filter first (some relays support prefix matching)
    var events = await _relayPool.fetch(
      NostrFilter(kinds: [31753], tags: {'#d': [prefix]}),
      timeout: const Duration(seconds: 8),
    );

    // If empty, try without d-tag filter (broader, matches Rails approach)
    if (events.isEmpty) {
      events = await _relayPool.fetch(
        NostrFilter(kinds: [31753]),
        timeout: const Duration(seconds: 8),
      );
    }

    debugPrint('[MemberSync] Fetched ${events.length} Kind 31753 events, prefix: $prefix');

    // Also ensure the local user is always a member
    final users = await _db.select(_db.users).get();
    if (users.isNotEmpty) {
      final localPubkey = users.first.nostrPublicKey;
      if (localPubkey != null) {
        await _ensureRemoteMember(serverId, localPubkey);
      }
    }
    final memberEvents = events.where((e) {
      final dTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
      return dTag != null && dTag.length > 1 && dTag[1].startsWith(prefix);
    }).toList();

    // Group by d-tag and take latest per member
    final grouped = <String, nostr.NostrEvent>{};
    for (final e in memberEvents) {
      final dTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'd').first[1];
      final existing = grouped[dTag];
      if (existing == null || e.createdAt > existing.createdAt) {
        grouped[dTag] = e;
      }
    }

    final now = DateTime.now();
    for (final event in grouped.values) {
      // Get member pubkey from p tag
      final pTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'p').firstOrNull;
      if (pTag == null || pTag.length < 2) continue;

      final memberPubkey = pTag[1];
      final removed = event.tags.where((t) => t.isNotEmpty && t[0] == 'removed').firstOrNull;
      if (removed != null && removed.length > 1 && removed[1] == 'true') {
        // Remove member
        await (_db.delete(_db.remoteMembers)
              ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(memberPubkey)))
            .go();
        continue;
      }

      // Get role info from tags
      final roleTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'role').firstOrNull;

      final publicId = memberPubkey.substring(0, 12);
      await _db.into(_db.remoteMembers).insertOnConflictUpdate(
        RemoteMembersCompanion.insert(
          publicId: Value(publicId),
          serverId: serverId,
          pubkey: memberPubkey,
          joinedAt: Value(DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000)),
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Fetch profile for this member (Kind 0)
      _fetchMemberProfile(memberPubkey);
    }
  }

  /// Fetch a member's Kind 0 profile and update contacts + remote_members
  Future<void> _fetchMemberProfile(String pubkey) async {
    try {
      final events = await _relayPool.fetch(
        NostrFilter(kinds: [0], authors: [pubkey], limit: 1),
        timeout: const Duration(seconds: 5),
      );
      if (events.isEmpty) return;

      final profile = json.decode(events.first.content) as Map<String, dynamic>;
      final now = DateTime.now();

      // Update contacts table
      await _db.into(_db.contacts).insertOnConflictUpdate(
        ContactsCompanion.insert(
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
        ),
      );

      // Update remote_members with profile data
      await (_db.update(_db.remoteMembers)
            ..where((m) => m.pubkey.equals(pubkey)))
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
        final events = await _relayPool.fetch(
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

  /// Ensure a remote member exists for a pubkey in a server
  Future<void> _ensureRemoteMember(int serverId, String pubkey) async {
    final existing = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (existing != null) return;

    final now = DateTime.now();
    final publicId = pubkey.substring(0, 12);
    await _db.into(_db.remoteMembers).insertOnConflictUpdate(
      RemoteMembersCompanion.insert(
        publicId: Value(publicId),
        serverId: serverId,
        pubkey: pubkey,
        createdAt: now,
        updatedAt: now,
      ),
    );

    // Fetch profile in background
    _fetchMemberProfile(pubkey);
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
