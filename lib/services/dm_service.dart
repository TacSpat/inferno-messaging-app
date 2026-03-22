import 'dart:convert';
import 'package:drift/drift.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../crypto/nip44_crypto.dart';
import '../crypto/nostr_key.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';

class DmService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  DmService(this._db, this._relayPool);

  /// Send a DM to a recipient
  Future<Message?> sendDm({
    required String privateKeyHex,
    required String publicKeyHex,
    required String recipientPubkey,
    required String content,
    List<String>? fileUrls,
  }) async {
    // Build payload — structured JSON if files, plain text otherwise
    String payload;
    if (fileUrls != null && fileUrls.isNotEmpty) {
      payload = json.encode({
        'type': 'message',
        'content': content,
        'files': fileUrls,
      });
    } else {
      payload = content;
    }

    // Encrypt with NIP-44
    final convKey = Nip44Crypto.conversationKey(privateKeyHex, recipientPubkey);
    final encrypted = Nip44Crypto.encrypt(payload, convKey);

    // Build Kind 14 event
    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 14,
      tags: [
        ['p', recipientPubkey],
      ],
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
        createdAt: now,
        updatedAt: now,
      ),
    );

    // Update conversation timestamp
    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversation.id)))
        .write(ConversationsCompanion(updatedAt: Value(now)));

    // Publish to relays
    _relayPool.publish(signed);

    return (_db.select(_db.messages)..where((m) => m.id.equals(msgId)))
        .getSingleOrNull();
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
    if (parsed != null) {
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
      }
    }

    // Regular message
    final content = parsed != null && parsed['type'] == 'message'
        ? parsed['content'] as String? ?? ''
        : plaintext;
    final fileUrls = parsed != null && parsed['files'] is List
        ? json.encode(parsed['files'])
        : null;

    final conversation = await _getOrCreateConversation(counterpartyPubkey);
    final publicId = NostrKey.bytesToHex(
      NostrKey.hexToBytes(event.id!).sublist(0, 6),
    );

    final now = DateTime.now();
    final eventTime = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);

    await _db.into(_db.messages).insert(
      MessagesCompanion.insert(
        publicId: publicId,
        content: Value(content),
        conversationId: Value(conversation.id),
        nostrAuthorPubkey: Value(senderPubkey),
        nostrEventId: Value(event.id),
        nostrEventJson: Value(json.encode(event.toJson())),
        fileUrls: fileUrls != null ? Value(fileUrls) : const Value.absent(),
        createdAt: eventTime,
        updatedAt: now,
      ),
    );

    await (_db.update(_db.conversations)
          ..where((c) => c.id.equals(conversation.id)))
        .write(ConversationsCompanion(updatedAt: Value(now)));
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

    // Update local contact status
    await _db.into(_db.contacts).insertOnConflictUpdate(
      ContactsCompanion.insert(
        pubkey: recipientPubkey,
        friendshipStatus: const Value(1), // pending_outgoing
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
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

    return (await (_db.select(_db.conversations)..where((c) => c.id.equals(id))).getSingle());
  }

  Future<void> _handleFriendRequest(String senderPubkey) async {
    await _db.into(_db.contacts).insertOnConflictUpdate(
      ContactsCompanion.insert(
        pubkey: senderPubkey,
        friendshipStatus: const Value(2), // pending_incoming
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<void> _handleFriendResponse(String senderPubkey, String? status) async {
    if (status == 'accepted') {
      await (_db.update(_db.contacts)
            ..where((c) => c.pubkey.equals(senderPubkey)))
          .write(ContactsCompanion(
        friendshipStatus: const Value(3), // accepted
        updatedAt: Value(DateTime.now()),
      ));
    } else if (status == 'declined') {
      await (_db.update(_db.contacts)
            ..where((c) => c.pubkey.equals(senderPubkey)))
          .write(ContactsCompanion(
        friendshipStatus: const Value(4), // declined
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
