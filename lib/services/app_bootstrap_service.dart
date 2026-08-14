import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/relay_auth.dart';
import '../nostr/nostr_filter.dart';
import '../services/relay_config_service.dart';
import '../services/auth_service.dart';
import '../services/dm_service.dart';
import '../services/group_message_service.dart';
import '../services/contact_service.dart';
import '../services/reaction_service.dart';
import '../services/presence_service.dart';
import '../services/typing_service.dart';
import '../services/server_sync_service.dart';
import '../services/invite_service.dart';
import '../services/media_cache_service.dart';
import '../services/content_safety_service.dart';
import '../services/config_sync_service.dart';
import '../services/relay_sync_service.dart';
import '../utils/device_id.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/shared_hash_service.dart';
import '../services/nsfw_detector.dart';

class AppBootstrapService {
  final InfernoDatabase db;
  final RelayPool relayPool;
  final AuthService authService;

  // Services — must be the SAME instances used by UI (from Riverpod providers)
  final DmService dmService;
  final GroupMessageService groupMessageService;
  final ContactService contactService;
  final ReactionService reactionService;
  final PresenceService presenceService;
  final TypingService typingService;
  final InviteService inviteService;
  final MediaCacheService? mediaCacheService;
  late final RelayConfigService relayConfig;
  late final ContentSafetyService contentSafety;
  late final SharedHashService sharedHashService;
  Timer? _resyncTimer;

  /// Tracks the latest Kind 0 `createdAt` (Nostr unix seconds) we've applied
  /// per pubkey so older events from slow relays don't overwrite newer data.
  final Map<String, int> _latestKind0 = {};

  AppBootstrapService({
    required this.db,
    required this.relayPool,
    required this.authService,
    required this.presenceService,
    required this.typingService,
    required this.reactionService,
    required this.groupMessageService,
    required this.dmService,
    required this.contactService,
    required this.inviteService,
    this.mediaCacheService,
  }) {
    relayConfig = RelayConfigService(db);
    contentSafety = ContentSafetyService(db);
    sharedHashService = SharedHashService(db, relayPool);
  }

  Future<void> bootstrap() async {
    // 0. Warm media dimension cache (fast, single SELECT)
    mediaCacheService?.warmUp();

    // 1. Ensure default relays + local user (fast, DB only)
    await relayConfig.ensureDefaultRelays();
    await _ensureLocalUser();

    // 1b. Warm the device id, but never block startup on it. It reads secure
    // storage, which on Linux goes through libsecret and can stall on a locked
    // or absent keyring — bootstrap must not be able to hang there.
    //
    // The Kind 10070 handler reads DeviceId.cached synchronously and already
    // treats a null value as "ours", so a slow warm-up degrades to the old
    // behaviour instead of misattributing another device's voice state.
    unawaited(DeviceId.get());

    // 2. Connect to relays in parallel (don't wait sequentially)
    final urls = await relayConfig.getActiveRelayUrls();
    if (urls.isNotEmpty) {
      await Future.wait(
        urls.map((url) => relayPool.addRelay(url)),
      ).timeout(const Duration(seconds: 3), onTimeout: () => []);
    }

    // 2b. Set auth credentials for fetchFresh NIP-42 support
    relayPool.authPrivateKeyHex = authService.privateKeyHex;
    relayPool.authPublicKeyHex = authService.publicKeyHex;

    // 3. Set up inbound event handlers (instant)
    _setupEventHandlers();

    // 4. Publish presence (fire and forget)
    if (authService.privateKeyHex != null && authService.publicKeyHex != null) {
      presenceService.startPeriodicPublish(
        authService.privateKeyHex!,
        authService.publicKeyHex!,
      );
    }

    // 5. Subscribe to relevant events
    await _setupSubscriptions();

    // 6. Start periodic server resync (every 60 minutes, matches Rails hourly sync)
    _startPeriodicResync();

    // 7. Initialize NSFW detector (non-blocking — falls back gracefully)
    NsfwDetector.instance.init();

    // 8. Start shared hash fetching (if enabled)
    sharedHashService.start();
  }

  /// Periodically resync all joined servers from relays (structure, members, etc.)
  void _startPeriodicResync() {
    _resyncTimer?.cancel();
    _resyncTimer = Timer.periodic(const Duration(minutes: 60), (_) => _resyncAllServers());
  }

  Future<void> _resyncAllServers() async {
    final servers = await db.select(db.servers).get();
    final syncService = ServerSyncService(db, relayPool);

    for (final server in servers) {
      if (server.nostrGroupId == null) continue;
      // Yield between servers so UI stays responsive during multi-server resync
      await Future.delayed(Duration.zero);
      // If any voice channel on this server has no sidechat link yet, force
      // a fresh sync so existing installs pick up sidechat publications that
      // were made before the Flutter client learned how to parse tag[12].
      final voiceWithoutSidechat = await (db.select(db.channels)
            ..where((c) => c.serverId.equals(server.id) &
                c.channelType.equals(1) &
                c.sidechatChannelId.isNull())
            ..limit(1))
          .getSingleOrNull();
      final shouldForce = voiceWithoutSidechat != null;
      try {
        // Periodic resync uses 30-minute throttle — skips if recently synced,
        // unless we need a fresh structure pull for sidechat backfill.
        await syncService.syncServer(
          server.nostrGroupId!,
          force: shouldForce,
          minInterval: const Duration(minutes: 30),
        );
      } catch (e) {
        debugPrint('[Resync] Failed to sync ${server.name}: $e');
      }
    }
  }

  void dispose() {
    _resyncTimer?.cancel();
    presenceService.dispose();
    typingService.dispose();
    sharedHashService.dispose();
    NsfwDetector.instance.dispose();
  }

  /// Fire-and-forget safety check on a message by its nostrEventId.
  void _runSafetyCheck(String nostrEventId) {
    // Run async without blocking the event handler
    () async {
      try {
        final message = await (db.select(db.messages)
              ..where((m) => m.nostrEventId.equals(nostrEventId)))
            .getSingleOrNull();
        if (message != null) {
          await contentSafety.check(message.id);
        }
      } catch (e) {
        debugPrint('[ContentSafety] Check failed for event $nostrEventId: $e');
      }
    }();
  }

  Future<void> _ensureLocalUser() async {
    if (authService.publicKeyHex == null) return;

    final existing = await (db.select(db.users)
          ..where((u) => u.nostrPublicKey.equals(authService.publicKeyHex!)))
        .getSingleOrNull();
    if (existing != null) return;

    final now = DateTime.now();
    final publicId = authService.publicKeyHex!.substring(0, 12);
    await db.into(db.users).insert(UsersCompanion.insert(
      publicId: publicId,
      username: 'user',
      nostrPublicKey: Value(authService.publicKeyHex),
      createdAt: now,
      updatedAt: now,
    ));
  }

  void _setupEventHandlers() {
    final privKey = authService.privateKeyHex;
    final pubKey = authService.publicKeyHex;

    // Kind 9: Group messages
    relayPool.onKind(9, (relayUrl, event) async {
      // Check dedup
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;
      await groupMessageService.processInboundMessage(event, privKey);
      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 9, pubkey: event.pubkey,
        );
        // Run content safety check on the newly inserted message
        _runSafetyCheck(event.id!);
      }
    });

    // Kind 9005: Message deletions
    relayPool.onKind(9005, (relayUrl, event) async {
      final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
      if (eTag != null && eTag.length > 1) {
        await (db.delete(db.messages)..where((m) => m.nostrEventId.equals(eTag[1]))).go();
      }
    });

    // Kind 9006: Message pins
    relayPool.onKind(9006, (relayUrl, event) async {
      final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
      final pinnedTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'pinned').firstOrNull;
      if (eTag != null && eTag.length > 1) {
        final pinned = pinnedTag != null && pinnedTag.length > 1 && pinnedTag[1] == 'true';
        await (db.update(db.messages)..where((m) => m.nostrEventId.equals(eTag[1])))
            .write(MessagesCompanion(pinned: Value(pinned), updatedAt: Value(DateTime.now())));
      }
    });

    // Kind 14: DMs
    relayPool.onKind(14, (relayUrl, event) async {
      if (privKey == null || pubKey == null) return;
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;
      await dmService.processInboundDm(event, privKey, pubKey);
      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: event.pubkey == pubKey ? 'outbound' : 'inbound',
          kind: 14, pubkey: event.pubkey,
        );
        // Run content safety check on the newly inserted message
        _runSafetyCheck(event.id!);
      }
    });

    // Kind 0: Profile updates — cache in contacts AND update remote_members.
    // Kind 0 is a Nostr "replaceable" event: only the latest (highest
    // createdAt) should be applied. Multiple relays may deliver stale copies
    // out of order, so we track the newest we've seen per pubkey and skip
    // anything older to avoid overwriting fresh data (especially our OWN
    // profile) with an outdated event from a slow relay.
    relayPool.onKind(0, (relayUrl, event) async {
      try {
        // _latestKind0 is in-memory, so it starts empty on every launch. Seed
        // it from what we previously applied, otherwise the FIRST Kind 0 to
        // arrive after a restart wins unconditionally — including a stale copy
        // from a slow relay, which reverts the profile until a newer event
        // arrives and corrects it.
        var latest = _latestKind0[event.pubkey] ?? 0;
        if (latest == 0) {
          final applied = await relayConfig.latestAppliedCreatedAt(
            kind: 0,
            pubkey: event.pubkey,
          );
          if (applied != null) {
            latest = applied.millisecondsSinceEpoch ~/ 1000;
            _latestKind0[event.pubkey] = latest;
          }
        }
        if (event.createdAt <= latest) return; // stale — skip
        _latestKind0[event.pubkey] = event.createdAt;

        final profile = json.decode(event.content) as Map<String, dynamic>;
        final now = DateTime.now();
        // Upsert contact (check-then-insert/update to avoid unique constraint on pubkey)
        final existingContact = await (db.select(db.contacts)
              ..where((c) => c.pubkey.equals(event.pubkey)))
            .getSingleOrNull();
        if (existingContact != null) {
          await (db.update(db.contacts)..where((c) => c.pubkey.equals(event.pubkey)))
              .write(ContactsCompanion(
            username: Value(profile['name'] as String?),
            displayName: Value(profile['display_name'] as String?),
            bio: Value(profile['about'] as String?),
            avatarUrl: Value(profile['picture'] as String?),
            bannerUrl: Value(profile['banner'] as String?),
            nip05: Value(profile['nip05'] as String?),
            status: Value(profile['status'] as String?),
            statusEmoji: Value(profile['status_emoji'] as String?),
            profileFetchedAt: Value(now),
            updatedAt: Value(now),
          ));
        } else {
          try {
            await db.into(db.contacts).insert(ContactsCompanion.insert(
              pubkey: event.pubkey,
              username: Value(profile['name'] as String?),
              displayName: Value(profile['display_name'] as String?),
              bio: Value(profile['about'] as String?),
              avatarUrl: Value(profile['picture'] as String?),
              bannerUrl: Value(profile['banner'] as String?),
              nip05: Value(profile['nip05'] as String?),
              status: Value(profile['status'] as String?),
              statusEmoji: Value(profile['status_emoji'] as String?),
              profileFetchedAt: Value(now),
              createdAt: now,
              updatedAt: now,
            ));
          } catch (_) {}
        }
        // Also update remote_members so member list shows updated profiles live
        await (db.update(db.remoteMembers)
              ..where((m) => m.pubkey.equals(event.pubkey)))
            .write(RemoteMembersCompanion(
          username: Value(profile['name'] as String?),
          displayName: Value(profile['display_name'] as String?),
          bio: Value(profile['about'] as String?),
          avatarUrl: Value(profile['picture'] as String?),
          bannerUrl: Value(profile['banner'] as String?),
          nip05: Value(profile['nip05'] as String?),
          status: Value(profile['status'] as String?),
          statusEmoji: Value(profile['status_emoji'] as String?),
          profileFetchedAt: Value(now),
          updatedAt: Value(now),
        ));

        // Record the version we applied so the ordering guard survives a
        // restart. profileFetchedAt is when we fetched, not the event's
        // created_at, so it cannot serve as the version.
        if (event.id != null) {
          await relayConfig.markEventProcessed(
            eventId: event.id!,
            direction: 'inbound',
            kind: 0,
            pubkey: event.pubkey,
            eventCreatedAt:
                DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
          );
        }
      } catch (_) {}
    });

    // Kind 3: Contact list (follow list) — auto-accept friends, detect unfollows
    // Matches Rails relay_subscription_manager.rb#process_follow_list
    relayPool.onKind(3, (relayUrl, event) async {
      try {
        final senderPubkey = event.pubkey;
        // Don't process our own follow list
        if (senderPubkey == authService.publicKeyHex) return;

        final tags = event.tags;
        final followedPubkeys = tags
            .where((t) => t.isNotEmpty && t[0] == 'p')
            .map((t) => t.length > 1 ? t[1] : '')
            .where((p) => p.isNotEmpty)
            .toSet();
        final followsUs = authService.publicKeyHex != null &&
            followedPubkeys.contains(authService.publicKeyHex);

        final contact = await (db.select(db.contacts)
              ..where((c) => c.pubkey.equals(senderPubkey)))
            .getSingleOrNull();
        if (contact == null) return;
        if (contact.friendshipStatus == 5) return; // blocked

        if (followsUs) {
          if (contact.friendshipStatus == 1) {
            // pending_outgoing → they followed us back → auto-accept
            await (db.update(db.contacts)..where((c) => c.pubkey.equals(senderPubkey)))
                .write(ContactsCompanion(
              friendshipStatus: const Value(3),
              updatedAt: Value(DateTime.now()),
            ));
            debugPrint('[Kind3] Auto-accepted friend via follow list from ${senderPubkey.substring(0, 12)}');
          } else if (contact.friendshipStatus == 0 || contact.friendshipStatus == 4) {
            // not_friend or declined → treat as incoming request
            await (db.update(db.contacts)..where((c) => c.pubkey.equals(senderPubkey)))
                .write(ContactsCompanion(
              friendshipStatus: const Value(2),
              updatedAt: Value(DateTime.now()),
            ));
            debugPrint('[Kind3] Incoming follow (Kind 3) from ${senderPubkey.substring(0, 12)}');
          }
        } else {
          // They unfollowed us
          if (contact.friendshipStatus == 3) {
            await (db.update(db.contacts)..where((c) => c.pubkey.equals(senderPubkey)))
                .write(ContactsCompanion(
              friendshipStatus: const Value(0),
              updatedAt: Value(DateTime.now()),
            ));
            debugPrint('[Kind3] Unfollowed by ${senderPubkey.substring(0, 12)}');
          }
        }
      } catch (e) {
        debugPrint('[Kind3] Error processing follow list: $e');
      }
    });

    // Kind 31753: Member join/leave — live updates to member list
    relayPool.onKind(31753, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;

      final dTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
      if (dTag == null || dTag.length < 2) return;

      // Find which server this member event belongs to
      final serverTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'server').firstOrNull;
      if (serverTag == null || serverTag.length < 2) return;

      final serverGid = serverTag[1];
      final server = await (db.select(db.servers)
            ..where((s) => s.nostrGroupId.equals(serverGid)))
          .getSingleOrNull();
      if (server == null) return;

      final pTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'p').firstOrNull;
      if (pTag == null || pTag.length < 2) return;
      final memberPubkey = pTag[1];

      final removed = event.tags.where((t) => t.isNotEmpty && t[0] == 'removed').firstOrNull;
      if (removed != null && removed.length > 1 && removed[1] == 'true') {
        // Member left — remove from DB
        await (db.delete(db.remoteMembers)
              ..where((m) => m.serverId.equals(server.id) & m.pubkey.equals(memberPubkey)))
            .go();
        return;
      }

      // Member joined — upsert (check existing first to avoid unique constraint conflict)
      final now = DateTime.now();
      final existing = await (db.select(db.remoteMembers)
            ..where((m) => m.serverId.equals(server.id) & m.pubkey.equals(memberPubkey)))
          .getSingleOrNull();
      if (existing == null) {
        final publicId = '${server.id.toRadixString(36)}${memberPubkey.substring(0, 8)}'.padLeft(12, '0').substring(0, 12);
        try {
          await db.into(db.remoteMembers).insert(
            RemoteMembersCompanion.insert(
              publicId: Value(publicId),
              serverId: server.id,
              pubkey: memberPubkey,
              createdAt: now,
              updatedAt: now,
            ),
          );
        } catch (_) {} // Race condition — another handler may have inserted
      }

      // Extract ALL embedded profile data from member event tags
      String? tag(String key) {
        final t = event.tags.where((t) => t.isNotEmpty && t[0] == key).firstOrNull;
        return (t != null && t.length > 1 && t[1].isNotEmpty) ? t[1] : null;
      }
      final profileName = tag('profile_name');
      final profileDisplayName = tag('profile_display_name');
      final profilePicture = tag('profile_picture');
      final profileColor = tag('profile_color');
      final profileColor2 = tag('profile_color_2');
      final profileStatus = tag('profile_status');
      final profileStatusEmoji = tag('profile_status_emoji');
      final profileAbout = tag('profile_about');
      final profileBanner = tag('profile_banner');
      final nickname = tag('nickname');

      // Update profile if ANY profile tag is present
      if (profileName != null || profileDisplayName != null || profilePicture != null || profileColor != null || profileStatus != null || nickname != null) {
        await (db.update(db.remoteMembers)
              ..where((m) => m.serverId.equals(server.id) & m.pubkey.equals(memberPubkey)))
            .write(RemoteMembersCompanion(
          username: profileName != null ? Value(profileName) : const Value.absent(),
          displayName: profileDisplayName != null ? Value(profileDisplayName) : const Value.absent(),
          avatarUrl: profilePicture != null ? Value(profilePicture) : const Value.absent(),
          bio: profileAbout != null ? Value(profileAbout) : const Value.absent(),
          bannerUrl: profileBanner != null ? Value(profileBanner) : const Value.absent(),
          profileColor: profileColor != null ? Value(profileColor) : const Value.absent(),
          profileColor2: profileColor2 != null ? Value(profileColor2) : const Value.absent(),
          status: profileStatus != null ? Value(profileStatus) : const Value.absent(),
          statusEmoji: profileStatusEmoji != null ? Value(profileStatusEmoji) : const Value.absent(),
          nickname: nickname != null ? Value(nickname) : const Value.absent(),
          updatedAt: Value(now),
        ));
      }

      // Update role assignments from "roles" tag
      final rolesTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'roles' && t.length >= 2).firstOrNull;
      if (rolesTag != null) {
        final member = await (db.select(db.remoteMembers)
              ..where((m) => m.serverId.equals(server.id) & m.pubkey.equals(memberPubkey)))
            .getSingleOrNull();
        if (member != null) {
          await (db.delete(db.remoteMembershipRoles)
                ..where((r) => r.remoteMemberId.equals(member.id)))
              .go();
          for (int i = 1; i < rolesTag.length; i++) {
            final rolePublicId = rolesTag[i];
            if (rolePublicId.isEmpty) continue;
            final role = await (db.select(db.roles)
                  ..where((r) => r.serverId.equals(server.id) & r.publicId.equals(rolePublicId)))
                .getSingleOrNull();
            if (role != null) {
              try {
                await db.into(db.remoteMembershipRoles).insert(
                  RemoteMembershipRolesCompanion.insert(
                    remoteMemberId: member.id, roleId: role.id,
                    createdAt: now, updatedAt: now,
                  ),
                );
              } catch (_) {}
            }
          }
        }
      }

      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31753, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
    });

    // Kind 31752: Role updates — live sync role changes
    relayPool.onKind(31752, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;

      final dTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
      if (dTag == null || dTag.length < 2) return;
      final serverTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'server').firstOrNull;
      final gid = serverTag != null && serverTag.length > 1 ? serverTag[1] : dTag[1].replaceFirst('inferno-roles-', '');
      final server = await (db.select(db.servers)..where((s) => s.nostrGroupId.equals(gid))).getSingleOrNull();
      if (server == null) return;

      for (final tag in event.tags) {
        if (tag.isEmpty || tag[0] != 'role' || tag.length < 3) continue;
        final color = tag.length > 3 ? tag[3] : null;
        final position = tag.length > 4 ? int.tryParse(tag[4]) ?? 0 : 0;
        final hoist = tag.length > 5 && tag[5] == 'true';
        final permissions = tag.length > 7 && tag[7].isNotEmpty ? tag[7] : null;

        final existingRole = await (db.select(db.roles)..where((r) => r.publicId.equals(tag[1]))).getSingleOrNull();
        final now = DateTime.now();
        if (existingRole != null) {
          await (db.update(db.roles)..where((r) => r.id.equals(existingRole.id)))
            .write(RolesCompanion(name: Value(tag[2]), color: Value(color), position: Value(position),
              hoist: Value(hoist), permissions: Value(permissions), updatedAt: Value(now)));
        } else {
          try {
            await db.into(db.roles).insert(RolesCompanion.insert(
              publicId: tag[1], serverId: server.id, name: Value(tag[2]),
              color: Value(color), position: Value(position), hoist: Value(hoist),
              permissions: Value(permissions), createdAt: now, updatedAt: now));
          } catch (_) {}
        }
      }
      debugPrint('[LiveSync] Roles updated for ${server.name}');

      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31752, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
    });

    // Kind 7: Reactions
    relayPool.onKind(7, (relayUrl, event) async {
      await reactionService.processInboundReaction(event);
    });

    // Kind 30315: Presence
    relayPool.onKind(30315, (relayUrl, event) {
      presenceService.processInboundPresence(event);
    });

    // Kind 25050: Typing indicators (channel + DM)
    relayPool.onKind(25050, (relayUrl, event) {
      typingService.processInboundTyping(
        event,
        selfPubkey: authService.publicKeyHex,
      );
    });

    // Kind 10070: Public voice state events (join/leave/update)
    relayPool.onKind(10070, (relayUrl, event) {
      try {
        final parsed = json.decode(event.content) as Map<String, dynamic>;
        if (parsed['type'] != 'voice_state_sync') return;

        // Skip only this device's own echo, not every event from our pubkey.
        // Previously any event authored by us was dropped, which meant a
        // device could never see that the same identity was in voice on
        // another device — the case that matters, since LiveKit will evict
        // one of them (#66).
        if (event.pubkey == authService.publicKeyHex) {
          final eventDevice = parsed['device_id'] as String?;
          final thisDevice = DeviceId.cached;
          // Events without a device_id predate this field; treat them as ours
          // and drop them, matching the old behaviour rather than surfacing a
          // phantom second session.
          if (eventDevice == null || thisDevice == null || eventDevice == thisDevice) {
            return;
          }
        }

        dmService.handleVoiceStateSync(parsed);
      } catch (_) {}
    });

    // Kind 31754: Server emoji updates (live)
    relayPool.onKind(31754, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;

      final serverTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'server').firstOrNull;
      if (serverTag == null || serverTag.length < 2) return;
      final nostrGroupId = serverTag[1];
      final server = await (db.select(db.servers)
            ..where((s) => s.nostrGroupId.equals(nostrGroupId)))
          .getSingleOrNull();
      if (server == null) return;
      debugPrint('[Live] Emoji update for ${server.name}');

      final seenNames = <String>{};
      final cacheMap = <String, String>{};
      for (final tag in event.tags) {
        if (tag.isEmpty || tag[0] != 'emoji' || tag.length < 3) continue;
        final name = tag[1];
        final url = tag[2];
        if (name.isEmpty || url.isEmpty) continue;
        seenNames.add(name);
        cacheMap[name] = url;
        final publicId = name.hashCode.abs().toRadixString(36).padLeft(12, '0').substring(0, 12);
        try {
          final existing = await (db.select(db.serverEmojis)
                ..where((e) => e.serverId.equals(server.id) & e.name.equals(name)))
              .getSingleOrNull();
          if (existing != null) {
            await (db.update(db.serverEmojis)..where((e) => e.id.equals(existing.id)))
                .write(ServerEmojisCompanion(url: Value(url), updatedAt: Value(DateTime.now())));
          } else {
            await db.into(db.serverEmojis).insert(ServerEmojisCompanion.insert(
              publicId: publicId, serverId: server.id, name: name, creatorId: 0,
              url: Value(url), createdAt: DateTime.now(), updatedAt: DateTime.now(),
            ));
          }
        } catch (_) {}
      }
      // Persist to global emoji cache — survives leaving this server and
      // subsequent server-side deletion of the emoji.
      if (cacheMap.isNotEmpty) {
        final now = DateTime.now();
        await db.batch((batch) {
          for (final entry in cacheMap.entries) {
            batch.insert(
              db.emojiCache,
              EmojiCacheCompanion.insert(name: entry.key, url: entry.value, lastSeenAt: now),
              mode: InsertMode.insertOrIgnore,
            );
          }
        });
      }
      // Remove emojis no longer in the event (deleted on Rails)
      final allEmojis = await (db.select(db.serverEmojis)
            ..where((e) => e.serverId.equals(server.id)))
          .get();
      for (final emoji in allEmojis) {
        if (!seenNames.contains(emoji.name)) {
          await (db.delete(db.serverEmojis)..where((e) => e.id.equals(emoji.id))).go();
        }
      }

      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31754, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
    });

    // Kind 31755: Server sticker updates (live)
    relayPool.onKind(31755, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;

      final serverTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'server').firstOrNull;
      if (serverTag == null || serverTag.length < 2) return;
      final nostrGroupId = serverTag[1];
      final server = await (db.select(db.servers)
            ..where((s) => s.nostrGroupId.equals(nostrGroupId)))
          .getSingleOrNull();
      if (server == null) return;
      debugPrint('[Live] Sticker update for ${server.name}');

      final seenNames = <String>{};
      for (final tag in event.tags) {
        if (tag.isEmpty || tag[0] != 'sticker' || tag.length < 4) continue;
        final name = tag[1];
        final description = tag[2];
        final url = tag[3];
        seenNames.add(name);
        final publicId = name.hashCode.abs().toRadixString(36).padLeft(12, '0').substring(0, 12);
        try {
          final existing = await (db.select(db.serverStickers)
                ..where((s) => s.serverId.equals(server.id) & s.name.equals(name)))
              .getSingleOrNull();
          if (existing != null) {
            await (db.update(db.serverStickers)..where((s) => s.id.equals(existing.id)))
                .write(ServerStickersCompanion(
                  url: Value(url),
                  description: Value(description.isNotEmpty ? description : null),
                  updatedAt: Value(DateTime.now()),
                ));
          } else {
            await db.into(db.serverStickers).insert(ServerStickersCompanion.insert(
              publicId: publicId, serverId: server.id, name: name, creatorId: 0,
              url: Value(url),
              description: Value(description.isNotEmpty ? description : null),
              createdAt: DateTime.now(), updatedAt: DateTime.now(),
            ));
          }
        } catch (_) {}
      }
      // Remove stickers no longer in the event
      final allStickers = await (db.select(db.serverStickers)
            ..where((s) => s.serverId.equals(server.id)))
          .get();
      for (final sticker in allStickers) {
        if (!seenNames.contains(sticker.name)) {
          await (db.delete(db.serverStickers)..where((s) => s.id.equals(sticker.id))).go();
        }
      }

      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31755, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
    });

    // Kind 31757: Invite updates (live sync)
    relayPool.onKind(31757, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;
      final serverTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'server').firstOrNull;
      if (serverTag == null || serverTag.length < 2) return;
      final nostrGroupId = serverTag[1];
      final server = await (db.select(db.servers)
            ..where((s) => s.nostrGroupId.equals(nostrGroupId)))
          .getSingleOrNull();
      if (server == null) return;
      await inviteService.processInboundInvite(event, server);
      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31757, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
    });

    // Kind 31750: Server metadata updates — log for audit trail
    relayPool.onKind(31750, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;

      final dTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
      if (dTag == null || dTag.length < 2) return;
      final gid = dTag[1].replaceFirst('inferno-', '');
      final server = await (db.select(db.servers)..where((s) => s.nostrGroupId.equals(gid))).getSingleOrNull();
      if (server == null) return;

      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31750, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
      debugPrint('[LiveSync] Metadata update for ${server.name}');
    });

    // Kind 31751: Server structure updates — log for audit trail
    relayPool.onKind(31751, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;

      final dTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'd').firstOrNull;
      if (dTag == null || dTag.length < 2) return;
      final gid = dTag[1].replaceFirst('inferno-struct-', '');
      final server = await (db.select(db.servers)..where((s) => s.nostrGroupId.equals(gid))).getSingleOrNull();
      if (server == null) return;

      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31751, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
      debugPrint('[LiveSync] Structure update for ${server.name}');
    });

    // Kind 31756: Ban updates — log for audit trail
    relayPool.onKind(31756, (relayUrl, event) async {
      if (event.id != null && await relayConfig.isEventProcessed(event.id!)) return;

      final serverTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'server').firstOrNull;
      if (serverTag == null || serverTag.length < 2) return;
      final server = await (db.select(db.servers)..where((s) => s.nostrGroupId.equals(serverTag[1]))).getSingleOrNull();
      if (server == null) return;

      if (event.id != null) {
        await relayConfig.markEventProcessed(
          eventId: event.id!, direction: 'inbound',
          kind: 31756, pubkey: event.pubkey, serverId: server.id,
          eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000),
        );
      }
      debugPrint('[LiveSync] Ban update for ${server.name}');
    });

    // NIP-42 AUTH challenges — auto-respond with ["AUTH", event] to the specific relay
    relayPool.onAuthChallenge = (relayUrl, challenge) {
      if (privKey != null && pubKey != null) {
        final authEvent = RelayAuth.buildAuthEvent(
          challenge: challenge,
          relayUrl: relayUrl,
          privateKeyHex: privKey,
          publicKeyHex: pubKey,
        );
        relayPool.sendAuthToRelay(relayUrl, authEvent);
        debugPrint('[Auth] Responded to AUTH challenge from $relayUrl');
      }
    };
  }

  Future<void> _setupSubscriptions() async {
    if (authService.publicKeyHex == null) return;
    final pubKey = authService.publicKeyHex!;

    // Catch-up window. This was a hardcoded 24 hours, which silently lost
    // history on any device not opened daily — a laptop used weekly saw only
    // the last day, with no indication of the gap, and the hole was only
    // repaired if the user happened to click into each channel or DM.
    //
    // app_settings.backfillDays already existed for exactly this (default 30)
    // and was read nowhere. Bounded below at one day so a misconfigured 0 does
    // not disable catch-up entirely.
    final settings = await (db.select(db.appSettings)..limit(1)).getSingleOrNull();
    final backfillDays = (settings?.backfillDays ?? 30).clamp(1, 3650);
    final catchupSince =
        DateTime.now().subtract(Duration(days: backfillDays)).millisecondsSinceEpoch ~/ 1000;

    // Subscribe to inbound DMs
    relayPool.subscribe(key: 'dms-inbound', filters: [
      NostrFilter(kinds: [14, 1059], tags: {'#p': [pubKey]}, since: catchupSince),
    ]);

    // Subscribe to own outbound DMs (from other devices)
    relayPool.subscribe(key: 'dms-outbound', filters: [
      NostrFilter(kinds: [14, 1059], authors: [pubKey], since: catchupSince),
    ]);

    // Subscribe to profiles and presence from server members
    // Use persistent subscription — the onKind handlers filter relevant events
    // Don't filter by authors here since new members are discovered during sync
    // and we need to receive their presence events immediately
    final knownPubkeys = await _collectKnownPubkeys(pubKey);
    if (knownPubkeys.isNotEmpty) {
      // Profiles + contact lists: fetch from known authors only (efficient)
      relayPool.subscribe(key: 'profiles-contacts', filters: [
        NostrFilter(kinds: [0, 3], authors: knownPubkeys),
      ]);
    }
    // Presence + member events: subscribe broadly for live updates
    relayPool.subscribe(key: 'presence-members', filters: [
      NostrFilter(kinds: [30315, 31750, 31751, 31752, 31753, 31754, 31755, 31756, 31757], since: catchupSince),
    ]);

    // Subscribe to group messages for all joined channels
    _subscribeToChannels(catchupSince);

    // Fetch own profile from relays so user panel shows resolved name
    _fetchOwnProfile(pubKey);

    // Catch-up fetch for DM counterparties whose contact row is missing name
    // or avatar — the live subscription only gets future Kind 0 events so
    // stale conversations would otherwise show raw pubkeys forever.
    _backfillDmCounterpartyProfiles();

    // Cross-device config sync: fetch relay list + app config + server list
    // from relays so a fresh device bootstraps with the same setup.
    _syncConfigFromRelays(pubKey, authService.privateKeyHex);
  }

  Future<void> _syncConfigFromRelays(String pubKey, String? privKey) async {
    if (privKey == null) return;
    try {
      final configSvc = ConfigSyncService(relayPool);
      final relaySvc = RelaySyncService(relayPool);

      // NIP-65 relay list
      final relayList = await relaySvc.fetchRelayList(pubKey);
      if (relayList.isNotEmpty) {
        debugPrint('[ConfigSync] Fetched ${relayList.length} relays from NIP-65');
        // Merge with local relay config — add any relays we don't already have.
        for (final r in relayList) {
          // addRelay is a no-op if already connected.
          relayPool.addRelay(r.url);
          // Persist too, or the relay is forgotten on the next launch and the
          // NIP-65 list has to be refetched before anything can reach it.
          await relayConfig.addRelay(r.url);
        }
      }

      // Server list — discover which servers to sync on a fresh device
      final serverIds = await configSvc.fetchServerList(
        privateKeyHex: privKey, publicKeyHex: pubKey,
      );
      if (serverIds.isNotEmpty) {
        debugPrint('[ConfigSync] Fetched ${serverIds.length} servers from config');
        final syncService = ServerSyncService(db, relayPool);
        for (final gid in serverIds) {
          final existing = await (db.select(db.servers)..where((s) => s.nostrGroupId.equals(gid))).getSingleOrNull();
          if (existing == null) {
            try {
              await syncService.syncServer(gid, force: true);
            } catch (e) {
              debugPrint('[ConfigSync] Server sync failed for $gid: $e');
            }
          }
        }
      }

      // App settings — theme, audio, safety
      final config = await configSvc.fetchConfig(
        privateKeyHex: privKey, publicKeyHex: pubKey,
      );
      if (config != null) {
        debugPrint('[ConfigSync] Fetched app config from Kind 30078');
        // Store in secure storage for settings screens to read.
        // Only apply if we don't already have local overrides.
        final audio = config['audio'] as Map<String, dynamic>?;
        if (audio != null) {
          const storage = FlutterSecureStorage();
          final keys = {
            'voice_noise_suppression': audio['noiseSuppression'],
            'voice_echo_cancellation': audio['echoCancellation'],
            'voice_auto_gain_control': audio['autoGainControl'],
          };
          for (final entry in keys.entries) {
            final existing = await storage.read(key: entry.key);
            if (existing == null && entry.value != null) {
              await storage.write(key: entry.key, value: entry.value.toString());
            }
          }
        }
      }

      // Publish our own state back. Until now only the read half of config
      // sync ran, so nothing was ever written and a second device on the same
      // identity always came up empty — it queried for a Kind 30078 config and
      // a Kind 10002 relay list that had never been published by anyone.
      await publishConfigToRelays(pubKey, privKey);
    } catch (e) {
      debugPrint('[ConfigSync] Config sync failed: $e');
    }
  }

  /// Publish the local server list and relay list so other devices on this
  /// identity can discover them. Safe to call repeatedly — both are
  /// replaceable events keyed by d-tag.
  Future<void> publishConfigToRelays(String pubKey, String privKey) async {
    try {
      final configSvc = ConfigSyncService(relayPool);
      final relaySvc = RelaySyncService(relayPool);

      final servers = await db.select(db.servers).get();
      final groupIds = servers
          .where((s) => s.nostrGroupId != null)
          .map((s) => s.nostrGroupId!)
          .toList();
      if (groupIds.isNotEmpty) {
        await configSvc.publishServerList(
          privateKeyHex: privKey,
          publicKeyHex: pubKey,
          serverGroupIds: groupIds,
        );
        debugPrint('[ConfigSync] Published ${groupIds.length} servers');
      }

      final relayUrls = await relayConfig.getActiveRelayUrls();
      if (relayUrls.isNotEmpty) {
        await relaySvc.publishRelayList(
          privateKeyHex: privKey,
          publicKeyHex: pubKey,
          relays: relayUrls.map((u) => RelayEntry(url: u)).toList(),
        );
        debugPrint('[ConfigSync] Published ${relayUrls.length} relays (NIP-65)');
      }
    } catch (e) {
      debugPrint('[ConfigSync] Publish failed: $e');
    }
  }

  Future<void> _backfillDmCounterpartyProfiles() async {
    try {
      final conversations = await db.select(db.conversations).get();
      final pending = <String>[];
      for (final conv in conversations) {
        final pk = conv.counterpartyPubkey;
        if (pk == null) continue;
        final contact = await (db.select(db.contacts)
              ..where((c) => c.pubkey.equals(pk)))
            .getSingleOrNull();
        final hasName = (contact?.displayName?.isNotEmpty ?? false) ||
            (contact?.username?.isNotEmpty ?? false);
        if (!hasName) pending.add(pk);
      }
      if (pending.isEmpty) return;
      await contactService.fetchProfiles(pending);
    } catch (e) {
      debugPrint('[Bootstrap] DM profile backfill failed: $e');
    }
  }

  /// Collect all known pubkeys (contacts + remote members + own) for presence subscription.
  /// Matches Rails: RelaySubscriptionManager collects pubkeys from contacts, DM counterparties, and remote members.
  Future<List<String>> _collectKnownPubkeys(String ownPubkey) async {
    final pubkeys = <String>{ownPubkey};

    // Contacts
    final contacts = await db.select(db.contacts).get();
    for (final c in contacts) {
      pubkeys.add(c.pubkey);
    }

    // Remote members from all servers
    final members = await db.select(db.remoteMembers).get();
    for (final m in members) {
      pubkeys.add(m.pubkey);
    }

    // DM counterparties
    final conversations = await db.select(db.conversations).get();
    for (final c in conversations) {
      if (c.counterpartyPubkey != null) pubkeys.add(c.counterpartyPubkey!);
    }

    return pubkeys.toList();
  }

  Future<void> _subscribeToChannels(int catchupSince) async {
    final channels = await db.select(db.channels).get();
    final groupIds = channels
        .where((c) => c.nostrGroupId != null)
        .map((c) => c.nostrGroupId!)
        .toList();
    if (groupIds.isEmpty) return;

    // Server-level group IDs for voice state events
    final servers = await db.select(db.servers).get();
    final serverGroupIds = servers
        .where((s) => s.nostrGroupId != null)
        .map((s) => s.nostrGroupId!)
        .toList();

    // Keyed: _subscribeToChannels is re-run whenever the joined-channel set
    // changes, so it must replace its REQ rather than add another.
    relayPool.subscribe(key: 'joined-channels', filters: [
      NostrFilter(kinds: [9, 9005, 9006, 7, 25050], tags: {'#h': groupIds}, since: catchupSince),
      if (serverGroupIds.isNotEmpty)
        NostrFilter(kinds: [10070], tags: {'#h': serverGroupIds}, since: catchupSince),
    ]);
  }

  /// Fetch our own Kind 0 profile so the user panel shows our display name
  Future<void> _fetchOwnProfile(String pubKey) async {
    try {
      final events = await relayPool.fetch(
        NostrFilter(kinds: [0], authors: [pubKey], limit: 1),
        timeout: const Duration(seconds: 10),
      );
      if (events.isNotEmpty) {
        final event = events.first;
        final profile = json.decode(event.content) as Map<String, dynamic>;

        // Check-then-insert/update, NOT insertOnConflictUpdate.
        //
        // contacts.pubkey is a unique index but the primary key is the
        // autoIncrement id, and Drift builds ON CONFLICT against the primary
        // key only. Once a row for this pubkey existed, the insert raised a
        // unique-constraint error that the bare catch below swallowed, so the
        // user's own display name and avatar silently never updated again
        // after the first fetch.
        final existing = await (db.select(db.contacts)
              ..where((c) => c.pubkey.equals(pubKey)))
            .getSingleOrNull();

        if (existing == null) {
          await db.into(db.contacts).insert(
                ContactsCompanion.insert(
                  pubkey: pubKey,
                  username: Value(profile['name'] as String?),
                  displayName: Value(profile['display_name'] as String?),
                  bio: Value(profile['about'] as String?),
                  avatarUrl: Value(profile['picture'] as String?),
                  bannerUrl: Value(profile['banner'] as String?),
                  nip05: Value(profile['nip05'] as String?),
                  profileFetchedAt: Value(DateTime.now()),
                  createdAt: DateTime.now(),
                  updatedAt: DateTime.now(),
                ),
              );
        } else {
          await (db.update(db.contacts)..where((c) => c.pubkey.equals(pubKey)))
              .write(
            ContactsCompanion(
              username: Value(profile['name'] as String?),
              displayName: Value(profile['display_name'] as String?),
              bio: Value(profile['about'] as String?),
              avatarUrl: Value(profile['picture'] as String?),
              bannerUrl: Value(profile['banner'] as String?),
              nip05: Value(profile['nip05'] as String?),
              profileFetchedAt: Value(DateTime.now()),
              updatedAt: Value(DateTime.now()),
            ),
          );
        }
      }
    } catch (e) {
      // Previously a bare `catch (_) {}`, which is how the unique-constraint
      // failure above stayed invisible for so long.
      debugPrint('[AppBootstrap] _fetchOwnProfile failed: $e');
    }
  }
}
