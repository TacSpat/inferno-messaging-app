import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../crypto/nip44_crypto.dart';
import '../crypto/nostr_key.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';
import 'emoji_resolver.dart';

class DmService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;
  late final EmojiResolver _emojiResolver = EmojiResolver(_db);

  /// Pending voice token responses keyed by request_id
  final Map<String, Map<String, dynamic>> _voiceTokenResponses = {};

  /// Remote voice state events stream
  final _voiceStateController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get voiceStateStream => _voiceStateController.stream;

  /// Current remote voice states: channelPublicId -> list of user states
  final Map<String, List<Map<String, dynamic>>> remoteVoiceStates = {};

  /// Wait for a voice token response with the given request_id (with timeout)
  Future<Map<String, dynamic>?> waitForVoiceToken(String requestId, {Duration timeout = const Duration(seconds: 15)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_voiceTokenResponses.containsKey(requestId)) {
        return _voiceTokenResponses.remove(requestId);
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return null; // timed out
  }

  DmService(this._db, this._relayPool);

  /// Send a DM to a recipient
  Future<Message?> sendDm({
    required String privateKeyHex,
    required String publicKeyHex,
    required String recipientPubkey,
    required String content,
    List<String>? fileUrls,
    bool spoiler = false,
  }) async {
    // Resolve any :shortcode: emoji to URLs so the message is self-contained
    // (recipient can render them without access to the source server).
    final emojiUrls = await _emojiResolver.resolveInContent(content);

    // Build payload — structured JSON if files, spoiler, or custom emoji present
    String payload;
    if ((fileUrls != null && fileUrls.isNotEmpty) || spoiler || emojiUrls.isNotEmpty) {
      payload = json.encode({
        'type': 'message',
        'content': content,
        if (fileUrls != null && fileUrls.isNotEmpty) 'files': fileUrls,
        if (spoiler) 'spoiler': true,
        if (emojiUrls.isNotEmpty) 'emojis': emojiUrls,
      });
    } else {
      payload = content;
    }

    // Encrypt with NIP-44
    final convKey = Nip44Crypto.conversationKey(privateKeyHex, recipientPubkey);
    final encrypted = Nip44Crypto.encrypt(payload, convKey);

    // Build Kind 14 event. NIP-30 `emoji` tags live outside the ciphertext so they
    // can travel visibly on the event for clients that prefer tag-based rendering.
    final tags = <List<String>>[
      ['p', recipientPubkey],
    ];
    for (final entry in emojiUrls.entries) {
      tags.add(['emoji', entry.key, entry.value]);
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 14,
      tags: tags,
      content: encrypted,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);

    // Store message locally
    final conversation = await _getOrCreateConversation(recipientPubkey);
    final publicId = NostrKey.bytesToHex(
      NostrKey.hexToBytes(signed.id!).sublist(0, 6),
    );

    final now = DateTime.now();
    final msgId = await _db.into(_db.messages).insert(
      MessagesCompanion.insert(
        publicId: publicId,
        content: Value(content),
        conversationId: Value(conversation.id),
        nostrEventId: Value(signed.id),
        nostrEventJson: Value(json.encode(signed.toJson())),
        fileUrls: fileUrls != null ? Value(json.encode(fileUrls)) : const Value.absent(),
        customEmojiUrls: emojiUrls.isNotEmpty ? Value(json.encode(emojiUrls)) : const Value.absent(),
        createdAt: now,
        updatedAt: now,
      ),
    );

    // Update conversation timestamp
    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversation.id)))
        .write(ConversationsCompanion(updatedAt: Value(now)));

    // Publish to relays and await so the caller can tell the user if every
    // relay rejected it (rate limit / auth / etc).
    final results = await _relayPool.publishWithDetails(signed);
    lastSendResults = results;
    final anyOk = results.values.any((r) => r.ok);
    if (!anyOk) {
      final rateLimited = results.values.any((r) => r.isRateLimited);
      lastSendError = rateLimited
          ? 'Rate limited by relay — try again in a few seconds.'
          : _firstReason(results) ?? 'No relay accepted the message.';
    } else {
      lastSendError = null;
    }

    return (_db.select(_db.messages)..where((m) => m.id.equals(msgId)))
        .getSingleOrNull();
  }

  /// Most recent send result set (for UI to inspect per-relay outcomes).
  Map<String, PublishResult> lastSendResults = const {};

  /// Human-readable failure reason from the last send, or null on success.
  String? lastSendError;

  String? _firstReason(Map<String, PublishResult> r) {
    for (final v in r.values) {
      if (!v.ok && v.reason != null && v.reason!.isNotEmpty) return v.reason;
    }
    return null;
  }

  /// Process an inbound Kind 14 DM event
  Future<void> processInboundDm(
    nostr.NostrEvent event,
    String privateKeyHex,
    String publicKeyHex,
  ) async {
    final senderPubkey = event.pubkey;
    final isOwnEvent = senderPubkey == publicKeyHex;

    // Determine counterparty
    String counterpartyPubkey;
    if (isOwnEvent) {
      final pTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'p').firstOrNull;
      if (pTag == null || pTag.length < 2) return;
      counterpartyPubkey = pTag[1];
    } else {
      counterpartyPubkey = senderPubkey;
    }

    // Check if blocked
    final blocked = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(counterpartyPubkey) & c.friendshipStatus.equals(5)))
        .getSingleOrNull();
    if (blocked != null && !isOwnEvent) return;

    // Decrypt
    final convKey = Nip44Crypto.conversationKey(privateKeyHex, counterpartyPubkey);
    String plaintext;
    try {
      plaintext = Nip44Crypto.decrypt(event.content, convKey);
    } catch (_) {
      return; // Decryption failed
    }

    // Parse structured payload
    Map<String, dynamic>? parsed;
    try {
      parsed = json.decode(plaintext) as Map<String, dynamic>;
    } catch (_) {
      // Plain text message
    }

    // Handle special message types
    if (parsed != null && parsed['type'] != null) {
      debugPrint('[DM] Received type=${parsed['type']} from ${counterpartyPubkey.substring(0, 8)}');
      switch (parsed['type']) {
        case 'friend_request':
          if (!isOwnEvent) await _handleFriendRequest(counterpartyPubkey);
          return;
        case 'friend_response':
          if (!isOwnEvent) await _handleFriendResponse(counterpartyPubkey, parsed['status'] as String?);
          return;
        case 'message_delete':
          await _handleMessageDelete(parsed);
          return;
        case 'voice_token_response':
          debugPrint('[DM] Received voice_token_response request_id=${parsed['request_id']}');
          _voiceTokenResponses[parsed['request_id'] as String] = parsed;
          return;
        case 'voice_token_request':
          return;
        case 'voice_state_sync':
          debugPrint('[DM] Voice state: ${parsed['action']} ${parsed['username']} in ${parsed['channel_id']}');
          handleVoiceStateSync(parsed);
          return;
      }
    }

    // Any parsed JSON with a type that isn't 'message' is a system DM — drop it.
    // This catches unknown system types and prevents them from being stored as
    // visible messages (e.g. voice handshakes with non-friend providers).
    if (parsed != null && parsed['type'] != null && parsed['type'] != 'message') {
      return;
    }

    // Regular message
    final content = parsed != null && parsed['type'] == 'message'
        ? parsed['content'] as String? ?? ''
        : plaintext;
    final fileUrls = parsed != null && parsed['files'] is List
        ? json.encode(parsed['files'])
        : null;
    final isSpoiler = parsed != null && parsed['spoiler'] == true;

    // Collect custom emoji URLs from two sources, in priority order:
    //   1. NIP-30 `emoji` tags on the outer event
    //   2. `emojis` map inside the encrypted JSON payload (our own format)
    final emojiUrls = <String, String>{};
    for (final tag in event.tags) {
      if (tag.length >= 3 && tag[0] == 'emoji') {
        if (tag[1].isNotEmpty && tag[2].isNotEmpty) emojiUrls[tag[1]] = tag[2];
      }
    }
    if (parsed != null && parsed['emojis'] is Map) {
      final inner = (parsed['emojis'] as Map).cast<String, dynamic>();
      for (final entry in inner.entries) {
        final url = entry.value;
        if (url is String && url.isNotEmpty) emojiUrls.putIfAbsent(entry.key, () => url);
      }
    }

    // Persist every seen emoji so references in old messages keep working
    // after the user leaves the source server or the server deletes the emoji.
    if (emojiUrls.isNotEmpty) {
      await _emojiResolver.cacheAll(emojiUrls);
    }

    // Dedup: skip if we already have this message
    if (event.id != null) {
      final existing = await (_db.select(_db.messages)
            ..where((m) => m.nostrEventId.equals(event.id!)))
          .getSingleOrNull();
      if (existing != null) return;
    }

    final conversation = await _getOrCreateConversation(counterpartyPubkey);
    final publicId = NostrKey.bytesToHex(
      NostrKey.hexToBytes(event.id!).sublist(0, 6),
    );

    final now = DateTime.now();
    final eventTime = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);

    try {
    await _db.into(_db.messages).insert(
      MessagesCompanion.insert(
        publicId: publicId,
        content: Value(content),
        conversationId: Value(conversation.id),
        spoiler: Value(isSpoiler),
        nostrAuthorPubkey: Value(senderPubkey),
        nostrEventId: Value(event.id),
        nostrEventJson: Value(json.encode(event.toJson())),
        fileUrls: fileUrls != null ? Value(fileUrls) : const Value.absent(),
        customEmojiUrls: emojiUrls.isNotEmpty ? Value(json.encode(emojiUrls)) : const Value.absent(),
        createdAt: eventTime,
        updatedAt: now,
      ),
    );
    } catch (_) {
      // Duplicate message — already exists
      return;
    }

    // Use the message's createdAt time so backfilled old messages don't bump
    // the conversation to the top — only newer-than-current activity wins.
    final existing = await (_db.select(_db.conversations)
          ..where((c) => c.id.equals(conversation.id)))
        .getSingle();
    if (eventTime.isAfter(existing.updatedAt)) {
      await (_db.update(_db.conversations)
            ..where((c) => c.id.equals(conversation.id)))
          .write(ConversationsCompanion(updatedAt: Value(eventTime)));
    }
  }

  /// Send a friend request
  Future<void> sendFriendRequest({
    required String privateKeyHex,
    required String publicKeyHex,
    required String recipientPubkey,
  }) async {
    final payload = json.encode({'type': 'friend_request'});
    final convKey = Nip44Crypto.conversationKey(privateKeyHex, recipientPubkey);
    final encrypted = Nip44Crypto.encrypt(payload, convKey);

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 14,
      tags: [['p', recipientPubkey]],
      content: encrypted,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);

    // Update local contact status (use check-then-update — insertOnConflictUpdate
    // doesn't work for non-PK unique constraints like pubkey)
    final existing = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(recipientPubkey)))
        .getSingleOrNull();
    if (existing != null) {
      await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(recipientPubkey)))
          .write(ContactsCompanion(friendshipStatus: const Value(1), updatedAt: Value(DateTime.now())));
    } else {
      await _db.into(_db.contacts).insert(ContactsCompanion.insert(
        pubkey: recipientPubkey,
        friendshipStatus: const Value(1),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    }

    // Publish Kind 3 contact list so recipient can detect follow via standard Nostr
    _publishContactList(privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex);
  }

  /// Send a friend response (accept/decline)
  Future<void> sendFriendResponse({
    required String privateKeyHex,
    required String publicKeyHex,
    required String recipientPubkey,
    required String status, // "accepted" or "declined"
  }) async {
    final payload = json.encode({'type': 'friend_response', 'status': status});
    final convKey = Nip44Crypto.conversationKey(privateKeyHex, recipientPubkey);
    final encrypted = Nip44Crypto.encrypt(payload, convKey);

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 14,
      tags: [['p', recipientPubkey]],
      content: encrypted,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);

    // Update local contact status
    final newStatus = status == 'accepted' ? 3 : 4; // accepted or declined
    await (_db.update(_db.contacts)
          ..where((c) => c.pubkey.equals(recipientPubkey)))
        .write(ContactsCompanion(
      friendshipStatus: Value(newStatus),
      updatedAt: Value(DateTime.now()),
    ));

    // Publish updated Kind 3 contact list (matches Rails: NostrPublishJob.perform_later(:contacts))
    if (status == 'accepted') {
      _publishContactList(privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex);
    }
  }

  /// Publish Kind 3 contact list with all accepted friends.
  /// Matches Rails NostrPublishJob#build_contacts_event.
  void _publishContactList({required String privateKeyHex, required String publicKeyHex}) async {
    try {
      final friends = await (_db.select(_db.contacts)
            ..where((c) => c.friendshipStatus.isIn([1, 3]))) // pending_outgoing + accepted
          .get();
      final tags = friends.map((f) => [
        'p', f.pubkey, '', f.displayName ?? f.username ?? '',
      ]).toList();
      final event = nostr.NostrEvent(
        pubkey: publicKeyHex,
        createdAt: nostr.NostrEvent.now(),
        kind: 3,
        tags: tags,
        content: '',
      );
      final signer = NostrSigner(privateKeyHex: privateKeyHex);
      final signed = signer.sign(event);
      await _relayPool.publish(signed);
      debugPrint('[DM] Published Kind 3 contact list with ${friends.length} friends');
    } catch (e) {
      debugPrint('[DM] Failed to publish Kind 3: $e');
    }
  }

  // --- Private helpers ---

  Future<Conversation> _getOrCreateConversation(String counterpartyPubkey) async {
    final existing = await (_db.select(_db.conversations)
          ..where((c) => c.counterpartyPubkey.equals(counterpartyPubkey)))
        .getSingleOrNull();
    if (existing != null) return existing;

    final publicId = NostrKey.bytesToHex(
      NostrKey.hexToBytes(counterpartyPubkey).sublist(0, 6),
    );
    final now = DateTime.now();
    final id = await _db.into(_db.conversations).insert(
      ConversationsCompanion.insert(
        publicId: publicId,
        kind: const Value(0), // direct
        counterpartyPubkey: Value(counterpartyPubkey),
        createdAt: now,
        updatedAt: now,
      ),
    );

    // First time we've seen this counterparty — kick off a Kind 0 fetch so the
    // DM list shows their name/avatar instead of the raw pubkey.
    unawaited(_fetchCounterpartyProfile(counterpartyPubkey));

    return (await (_db.select(_db.conversations)..where((c) => c.id.equals(id))).getSingle());
  }

  Future<void> _fetchCounterpartyProfile(String pubkey) async {
    try {
      final filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 1);
      final events = await _relayPool.fetch(filter, timeout: const Duration(seconds: 8));
      if (events.isEmpty) return;
      events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final profile = json.decode(events.first.content) as Map<String, dynamic>;
      final now = DateTime.now();
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
        await _db.into(_db.contacts).insert(ContactsCompanion.insert(
          pubkey: pubkey,
          username: Value(profile['name'] as String?),
          displayName: Value(profile['display_name'] as String?),
          bio: Value(profile['about'] as String?),
          avatarUrl: Value(profile['picture'] as String?),
          bannerUrl: Value(profile['banner'] as String?),
          nip05: Value(profile['nip05'] as String?),
          friendshipStatus: const Value(0),
          profileFetchedAt: Value(now),
          createdAt: now,
          updatedAt: now,
        ));
      }
    } catch (e) {
      debugPrint('[DM] Failed to fetch counterparty profile: $e');
    }
  }

  void handleVoiceStateSync(Map<String, dynamic> data) {
    final channelId = data['channel_id'] as String?;
    final action = data['action'] as String?;
    final userId = data['user_id'] as String?;
    if (channelId == null || action == null || userId == null) return;

    switch (action) {
      case 'join':
        remoteVoiceStates.putIfAbsent(channelId, () => []);
        // Remove existing entry for this user (update)
        remoteVoiceStates[channelId]!.removeWhere((s) => s['user_id'] == userId);
        remoteVoiceStates[channelId]!.add(data);
      case 'update':
        final states = remoteVoiceStates[channelId];
        if (states != null) {
          final idx = states.indexWhere((s) => s['user_id'] == userId);
          if (idx != -1) {
            states[idx] = {...states[idx], ...data};
          }
        }
      case 'leave':
        remoteVoiceStates[channelId]?.removeWhere((s) => s['user_id'] == userId);
        if (remoteVoiceStates[channelId]?.isEmpty ?? false) {
          remoteVoiceStates.remove(channelId);
        }
    }
    _voiceStateController.add(data);
  }

  /// Publish voice state sync to server's voice providers and known remote instances
  Future<void> publishVoiceState({
    required String privateKeyHex,
    required String publicKeyHex,
    required String action, // 'join', 'update', 'leave'
    required String serverGroupId,
    required String channelPublicId,
    required String userDisplayName,
    String? avatarUrl,
    bool selfMute = false,
    bool selfDeaf = false,
    required List<String> targetPubkeys,
  }) async {
    final payload = json.encode({
      'type': 'voice_state_sync',
      'action': action,
      'server_nostr_group_id': serverGroupId,
      'channel_id': channelPublicId,
      'user_id': publicKeyHex.substring(0, 12),
      'user_pubkey': publicKeyHex,
      'username': userDisplayName,
      'avatar_url': avatarUrl,
      'self_mute': selfMute,
      'self_deaf': selfDeaf,
    });

    for (final targetPubkey in targetPubkeys) {
      if (targetPubkey == publicKeyHex) continue; // don't send to ourselves
      try {
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
      } catch (_) {}
    }
  }

  Future<void> _handleFriendRequest(String senderPubkey) async {
    debugPrint('[DM] Processing friend request from ${senderPubkey.substring(0, 8)}');
    final existing = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(senderPubkey)))
        .getSingleOrNull();
    if (existing != null) {
      // Don't overwrite accepted/declined/blocked status with pending
      final currentStatus = existing.friendshipStatus;
      if (currentStatus == 3 || currentStatus == 4 || currentStatus == 5) {
        debugPrint('[DM] Ignoring friend request — already ${currentStatus == 3 ? "accepted" : currentStatus == 4 ? "declined" : "blocked"}');
        return;
      }
      await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(senderPubkey)))
          .write(ContactsCompanion(
        friendshipStatus: const Value(2), // pending_incoming
        updatedAt: Value(DateTime.now()),
      ));
    } else {
      await _db.into(_db.contacts).insert(ContactsCompanion.insert(
        pubkey: senderPubkey,
        friendshipStatus: const Value(2),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    }
    debugPrint('[DM] Friend request saved: ${senderPubkey.substring(0, 8)} = pending_incoming');
  }

  Future<void> _handleFriendResponse(String senderPubkey, String? status) async {
    debugPrint('[DM] Friend response from ${senderPubkey.substring(0, 8)}: $status');
    final statusInt = status == 'accepted' ? 3 : (status == 'declined' ? 4 : null);
    if (statusInt != null) {
      await (_db.update(_db.contacts)
            ..where((c) => c.pubkey.equals(senderPubkey)))
          .write(ContactsCompanion(
        friendshipStatus: Value(statusInt),
        updatedAt: Value(DateTime.now()),
      ));
    }
  }

  Future<void> _handleMessageDelete(Map<String, dynamic> parsed) async {
    final eventId = parsed['event_id'] as String?;
    if (eventId == null) return;
    await (_db.delete(_db.messages)
          ..where((m) => m.nostrEventId.equals(eventId)))
        .go();
  }
}
