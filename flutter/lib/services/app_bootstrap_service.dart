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
  late final RelayConfigService relayConfig;
  Timer? _resyncTimer;

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
  }) {
    relayConfig = RelayConfigService(db);
  }

  Future<void> bootstrap() async {
    // 1. Ensure default relays + local user (fast, DB only)
    await relayConfig.ensureDefaultRelays();
    await _ensureLocalUser();

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
      try {
        debugPrint('[Resync] Syncing server: ${server.name}');
        await syncService.syncServer(server.nostrGroupId!);
      } catch (e) {
        debugPrint('[Resync] Failed to sync ${server.name}: $e');
      }
    }
  }

  void dispose() {
    _resyncTimer?.cancel();
    presenceService.dispose();
    typingService.dispose();
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
      }
    });

    // Kind 0: Profile updates — cache in contacts AND update remote_members
    relayPool.onKind(0, (relayUrl, event) async {
      try {
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
          profileFetchedAt: Value(now),
          updatedAt: Value(now),
        ));
      } catch (_) {}
    });

    // Kind 31753: Member join/leave — live updates to member list
    relayPool.onKind(31753, (relayUrl, event) async {
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

      // Extract embedded profile from member event
      String? tag(String key) {
        final t = event.tags.where((t) => t.isNotEmpty && t[0] == key).firstOrNull;
        return (t != null && t.length > 1 && t[1].isNotEmpty) ? t[1] : null;
      }
      final profileName = tag('profile_name');
      final profileDisplayName = tag('profile_display_name');
      final profilePicture = tag('profile_picture');
      if (profileName != null || profileDisplayName != null) {
        await (db.update(db.remoteMembers)
              ..where((m) => m.serverId.equals(server.id) & m.pubkey.equals(memberPubkey)))
            .write(RemoteMembersCompanion(
          username: Value(profileName),
          displayName: Value(profileDisplayName),
          avatarUrl: Value(profilePicture),
          bio: Value(tag('profile_about')),
          bannerUrl: Value(tag('profile_banner')),
          status: Value(tag('profile_status')),
          statusEmoji: Value(tag('profile_status_emoji')),
          updatedAt: Value(now),
        ));
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

    // Kind 25050: Typing indicators
    relayPool.onKind(25050, (relayUrl, event) {
      typingService.processInboundTyping(event);
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

    // Catchup window: fetch events since last 24 hours (matches Rails catchup_since)
    final catchupSince = DateTime.now().subtract(const Duration(hours: 24)).millisecondsSinceEpoch ~/ 1000;

    // Subscribe to inbound DMs
    relayPool.subscribe(filters: [
      NostrFilter(kinds: [14, 1059], tags: {'#p': [pubKey]}, since: catchupSince),
    ]);

    // Subscribe to own outbound DMs (from other devices)
    relayPool.subscribe(filters: [
      NostrFilter(kinds: [14, 1059], authors: [pubKey], since: catchupSince),
    ]);

    // Subscribe to profiles and presence from server members
    // Use persistent subscription — the onKind handlers filter relevant events
    // Don't filter by authors here since new members are discovered during sync
    // and we need to receive their presence events immediately
    final knownPubkeys = await _collectKnownPubkeys(pubKey);
    if (knownPubkeys.isNotEmpty) {
      // Profiles: fetch from known authors only (efficient)
      relayPool.subscribe(filters: [
        NostrFilter(kinds: [0], authors: knownPubkeys),
      ]);
    }
    // Presence + member events: subscribe broadly for live updates
    relayPool.subscribe(filters: [
      NostrFilter(kinds: [30315, 31753], since: catchupSince),
    ]);

    // Subscribe to group messages for all joined channels
    _subscribeToChannels(catchupSince);

    // Fetch own profile from relays so user panel shows resolved name
    _fetchOwnProfile(pubKey);
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

    relayPool.subscribe(filters: [
      NostrFilter(kinds: [9, 9005, 9006, 7, 25050], tags: {'#h': groupIds}, since: catchupSince),
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
        await db.into(db.contacts).insertOnConflictUpdate(
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
      }
    } catch (_) {}
  }
}
