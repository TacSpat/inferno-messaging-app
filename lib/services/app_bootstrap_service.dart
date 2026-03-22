import 'dart:convert';
import 'package:drift/drift.dart';
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

class AppBootstrapService {
  final InfernoDatabase db;
  final RelayPool relayPool;
  final AuthService authService;

  // Services initialized during bootstrap
  late final DmService dmService;
  late final GroupMessageService groupMessageService;
  late final ContactService contactService;
  late final ReactionService reactionService;
  late final PresenceService presenceService;
  late final TypingService typingService;
  late final RelayConfigService relayConfig;

  AppBootstrapService({
    required this.db,
    required this.relayPool,
    required this.authService,
  }) {
    dmService = DmService(db, relayPool);
    groupMessageService = GroupMessageService(db, relayPool);
    contactService = ContactService(db, relayPool);
    reactionService = ReactionService(db, relayPool);
    presenceService = PresenceService(relayPool);
    typingService = TypingService(relayPool);
    relayConfig = RelayConfigService(db);
  }

  Future<void> bootstrap() async {
    // 1. Ensure default relays
    await relayConfig.ensureDefaultRelays();

    // 2. Connect to relays
    final urls = await relayConfig.getActiveRelayUrls();
    if (urls.isNotEmpty) {
      await relayPool.start(urls);
    }

    // 3. Ensure local user record
    await _ensureLocalUser();

    // 4. Set up inbound event handlers
    _setupEventHandlers();

    // 5. Publish presence
    if (authService.privateKeyHex != null && authService.publicKeyHex != null) {
      presenceService.startPeriodicPublish(
        authService.privateKeyHex!,
        authService.publicKeyHex!,
      );
    }

    // 6. Subscribe to relevant events
    _setupSubscriptions();
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

    // Kind 0: Profile updates — cache in contacts
    relayPool.onKind(0, (relayUrl, event) async {
      try {
        final profile = json.decode(event.content) as Map<String, dynamic>;
        await db.into(db.contacts).insertOnConflictUpdate(
          ContactsCompanion.insert(
            pubkey: event.pubkey,
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
      } catch (_) {}
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

    // NIP-42 AUTH challenges — auto-respond
    relayPool.onAuthChallenge = (relayUrl, challenge) {
      if (privKey != null && pubKey != null) {
        final authEvent = RelayAuth.buildAuthEvent(
          challenge: challenge,
          relayUrl: relayUrl,
          privateKeyHex: privKey,
          publicKeyHex: pubKey,
        );
        // Send AUTH response back to the relay
        relayPool.publish(authEvent);
      }
    };
  }

  void _setupSubscriptions() {
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

    // Subscribe to profiles and presence of contacts
    relayPool.subscribe(filters: [
      NostrFilter(kinds: [0, 30315]),
    ]);

    // Subscribe to group messages for all joined channels
    _subscribeToChannels(catchupSince);

    // Fetch own profile from relays so user panel shows resolved name
    _fetchOwnProfile(pubKey);
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
