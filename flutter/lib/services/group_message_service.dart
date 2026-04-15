import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../crypto/nostr_key.dart';
import '../crypto/nip44_crypto.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import 'emoji_resolver.dart';

class GroupMessageService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;
  late final EmojiResolver _emojiResolver = EmojiResolver(_db);

  GroupMessageService(this._db, this._relayPool);

  /// Send a message to a channel
  Future<Message?> sendMessage({
    required String privateKeyHex,
    required String publicKeyHex,
    required Channel channel,
    required String content,
    String? parentEventId,
    bool spoiler = false,
  }) async {
    final tags = <List<String>>[
      ['h', channel.nostrGroupId ?? ''],
    ];

    // Reply tag
    if (parentEventId != null) {
      tags.add(['e', parentEventId, 'wss://relay.damus.io', 'reply']);
    }

    // Spoiler tag (matching Rails NostrGroupPublishJob)
    if (spoiler) {
      tags.add(['spoiler']);
    }

    // Extract @mention p-tags
    final mentionTags = await _extractMentionTags(content, channel.serverId);
    tags.addAll(mentionTags);

    // Attach NIP-30 custom emoji tags so message is self-contained
    final emojiUrls = await _emojiResolver.resolveInContent(content);
    for (final entry in emojiUrls.entries) {
      tags.add(['emoji', entry.key, entry.value]);
    }

    String eventContent = content;

    // Encrypt for encrypted channels
    if (channel.encrypted && channel.channelPublicKey != null) {
      final convKey = Nip44Crypto.conversationKey(privateKeyHex, channel.channelPublicKey!);
      eventContent = Nip44Crypto.encrypt(content, convKey);
      tags.add(['encrypted', 'nip44']);
      tags.add(['channel_pubkey', channel.channelPublicKey!]);
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 9,
      tags: tags,
      content: eventContent,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);

    // Store locally
    final publicId = NostrKey.bytesToHex(NostrKey.hexToBytes(signed.id!).sublist(0, 6));
    final now = DateTime.now();
    final msgId = await _db.into(_db.messages).insert(
      MessagesCompanion.insert(
        publicId: publicId,
        content: Value(content),
        channelId: Value(channel.id),
        spoiler: Value(spoiler),
        nostrAuthorPubkey: Value(publicKeyHex),
        nostrEventId: Value(signed.id),
        nostrEventJson: Value(json.encode(signed.toJson())),
        customEmojiUrls: emojiUrls.isNotEmpty ? Value(json.encode(emojiUrls)) : const Value.absent(),
        createdAt: now,
        updatedAt: now,
      ),
    );

    // Publish and log results
    final results = await _relayPool.publish(signed);
    results.forEach((url, success) {
      debugPrint('[GroupMessage] ${success ? "OK" : "FAIL"} $url');
    });

    return (_db.select(_db.messages)..where((m) => m.id.equals(msgId))).getSingleOrNull();
  }

  /// Process inbound Kind 9 group message
  Future<void> processInboundMessage(
    nostr.NostrEvent event,
    String? privateKeyHex,
  ) async {
    // Get channel from #h tag
    final hTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'h').firstOrNull;
    if (hTag == null || hTag.length < 2) return;

    final channel = await (_db.select(_db.channels)
          ..where((c) => c.nostrGroupId.equals(hTag[1])))
        .getSingleOrNull();
    if (channel == null) return;

    // Check for encrypted content
    String content = event.content;
    final encryptedTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'encrypted').firstOrNull;
    if (encryptedTag != null && privateKeyHex != null) {
      final channelPubkeyTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'channel_pubkey').firstOrNull;
      final channelPubkey = channelPubkeyTag != null && channelPubkeyTag.length > 1
          ? channelPubkeyTag[1]
          : channel.channelPublicKey;
      if (channelPubkey != null) {
        try {
          final convKey = Nip44Crypto.conversationKey(privateKeyHex, channelPubkey);
          content = Nip44Crypto.decrypt(event.content, convKey);
        } catch (_) {
          return; // Can't decrypt
        }
      }
    }

    // Check for edit tag — if present, update existing message instead of creating new
    final editTag = event.tags.where((t) =>
        t.length >= 4 && t[0] == 'e' && t[3] == 'edit').firstOrNull;
    if (editTag != null && editTag.length >= 2) {
      final originalEventId = editTag[1];
      await (_db.update(_db.messages)
            ..where((m) => m.nostrEventId.equals(originalEventId)))
          .write(MessagesCompanion(
        content: Value(content),
        editedAt: Value(DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000, isUtc: true)),
        updatedAt: Value(DateTime.now()),
      ));
      return; // Don't create a new message for edits
    }

    // Check for reply
    final replyTag = event.tags.where((t) =>
        t.length >= 4 && t[0] == 'e' && t[3] == 'reply').firstOrNull;
    int? parentId;
    if (replyTag != null) {
      final parent = await (_db.select(_db.messages)
            ..where((m) => m.nostrEventId.equals(replyTag[1])))
          .getSingleOrNull();
      parentId = parent?.id;
    }

    // Check for spoiler tag
    final spoilerTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'spoiler').firstOrNull;
    final isSpoiler = spoilerTag != null;

    // Collect NIP-30 custom emoji tags and persist to cache so they survive
    // server deletion / user leaving the server
    final emojiUrls = <String, String>{};
    for (final tag in event.tags) {
      if (tag.length >= 3 && tag[0] == 'emoji' && tag[1].isNotEmpty && tag[2].isNotEmpty) {
        emojiUrls[tag[1]] = tag[2];
      }
    }
    if (emojiUrls.isNotEmpty) {
      await _emojiResolver.cacheAll(emojiUrls);
    }

    // Skip if we already have this event (dedup relay echo)
    if (event.id != null) {
      final existing = await (_db.select(_db.messages)
            ..where((m) => m.nostrEventId.equals(event.id!)))
          .getSingleOrNull();
      if (existing != null) return;
    }

    final publicId = NostrKey.bytesToHex(NostrKey.hexToBytes(event.id!).sublist(0, 6));
    final eventTime = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000, isUtc: true);

    await _db.into(_db.messages).insert(
      MessagesCompanion.insert(
        publicId: publicId,
        content: Value(content),
        channelId: Value(channel.id),
        spoiler: Value(isSpoiler),
        nostrAuthorPubkey: Value(event.pubkey),
        nostrEventId: Value(event.id),
        nostrEventJson: Value(json.encode(event.toJson())),
        parentId: Value(parentId),
        customEmojiUrls: emojiUrls.isNotEmpty ? Value(json.encode(emojiUrls)) : const Value.absent(),
        createdAt: eventTime,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Send a message edit (Kind 9 with edit tag)
  Future<void> editMessage({
    required String privateKeyHex,
    required String publicKeyHex,
    required Channel channel,
    required String originalEventId,
    required String newContent,
  }) async {
    final tags = <List<String>>[
      ['h', channel.nostrGroupId ?? ''],
      // Use relay hint placeholder to prevent relays from stripping the empty string
      // which would shift "edit" from index 3 to index 2, breaking Rails' t[3] == "edit" check
      ['e', originalEventId, 'wss://relay.damus.io', 'edit'],
    ];

    String eventContent = newContent;
    if (channel.encrypted && channel.channelPublicKey != null) {
      final convKey = Nip44Crypto.conversationKey(privateKeyHex, channel.channelPublicKey!);
      eventContent = Nip44Crypto.encrypt(newContent, convKey);
      tags.add(['encrypted', 'nip44']);
      tags.add(['channel_pubkey', channel.channelPublicKey!]);
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 9,
      tags: tags,
      content: eventContent,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    debugPrint('[GroupMessage] EDIT event tags: ${signed.tags}');
    final results = await _relayPool.publish(signed);
    results.forEach((url, ok) => debugPrint('[GroupMessage] Edit ${ok ? "OK" : "FAIL"} $url'));

    // Update locally
    await (_db.update(_db.messages)
          ..where((m) => m.nostrEventId.equals(originalEventId)))
        .write(MessagesCompanion(
      content: Value(newContent),
      editedAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Send a message deletion (Kind 9005)
  Future<void> deleteMessage({
    required String privateKeyHex,
    required String publicKeyHex,
    required Channel channel,
    required String eventId,
  }) async {
    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 9005,
      tags: [
        ['h', channel.nostrGroupId ?? ''],
        ['e', eventId],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);

    // Delete locally
    await (_db.delete(_db.messages)..where((m) => m.nostrEventId.equals(eventId))).go();
  }

  /// Toggle pin on a message (Kind 9006)
  Future<void> togglePin({
    required String privateKeyHex,
    required String publicKeyHex,
    required Channel channel,
    required Message message,
  }) async {
    final newPinned = !(message.pinned ?? false);
    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 9006,
      tags: [
        ['h', channel.nostrGroupId ?? ''],
        ['e', message.nostrEventId ?? ''],
        ['pinned', newPinned.toString()],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);

    await (_db.update(_db.messages)..where((m) => m.id.equals(message.id)))
        .write(MessagesCompanion(pinned: Value(newPinned), updatedAt: Value(DateTime.now())));
  }

  static final _atMentionRegex = RegExp(r'(?:^|\s)@(\w+)');

  /// Extract Nostr p-tags for @mentioned users and roles in content
  Future<List<List<String>>> _extractMentionTags(String content, int serverId) async {
    final matches = _atMentionRegex.allMatches(content);
    if (matches.isEmpty) return [];

    final members = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId)))
        .get();
    final roles = await (_db.select(_db.roles)
          ..where((r) => r.serverId.equals(serverId)))
        .get();

    final tags = <List<String>>[];
    final seen = <String>{};
    for (final match in matches) {
      final username = match.group(1)!.toLowerCase();
      // Skip special mentions
      if (username == 'everyone' || username == 'here') continue;

      // Check if it's a role mention
      final role = roles.where((r) => r.name?.toLowerCase() == username).firstOrNull;
      if (role != null) {
        // Find all members with this role and add p-tags for each
        final memberRoles = await (_db.select(_db.remoteMembershipRoles)
              ..where((mr) => mr.roleId.equals(role.id)))
            .get();
        for (final mr in memberRoles) {
          final member = members.where((m) => m.id == mr.remoteMemberId).firstOrNull;
          if (member != null && !seen.contains(member.pubkey)) {
            tags.add(['p', member.pubkey]);
            seen.add(member.pubkey);
          }
        }
        continue;
      }

      // Find member by username or display name
      final member = members.where((m) =>
          (m.username?.toLowerCase() == username) ||
          (m.displayName?.toLowerCase() == username)).firstOrNull;
      if (member != null && !seen.contains(member.pubkey)) {
        tags.add(['p', member.pubkey]);
        seen.add(member.pubkey);
      }
    }
    return tags;
  }
}
