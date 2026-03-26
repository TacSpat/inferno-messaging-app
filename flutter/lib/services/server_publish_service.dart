import 'dart:convert';
import 'package:drift/drift.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';

class ServerPublishService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  ServerPublishService(this._db, this._relayPool);

  /// Publish Kind 31750 server metadata
  Future<void> publishMetadata({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
  }) async {
    final gid = server.nostrGroupId ?? '';
    final tags = <List<String>>[
      ['d', 'inferno-$gid'],
      ['name', server.name],
      ['about', server.description ?? ''],
    ];

    if (server.iconUrl != null) tags.add(['picture', server.iconUrl!]);
    if (server.bannerUrl != null) tags.add(['banner', server.bannerUrl!]);

    // Relay URLs
    if (server.relayUrls != null) {
      try {
        final urls = json.decode(server.relayUrls!) as List;
        for (final url in urls) {
          tags.add(['relay', url.toString()]);
        }
      } catch (_) {}
    }

    tags.add(['discoverable', server.discoverable.toString()]);
    tags.add(['voice_enabled', server.voiceEnabled.toString()]);

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31750,
      tags: tags,
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
  }

  /// Publish Kind 31751 server structure (channels + categories)
  Future<void> publishStructure({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
  }) async {
    final gid = server.nostrGroupId ?? '';
    final tags = <List<String>>[
      ['d', 'inferno-struct-$gid'],
    ];

    // Add categories
    final categories = await (_db.select(_db.categories)
          ..where((c) => c.serverId.equals(server.id))
          ..orderBy([(c) => OrderingTerm.asc(c.position)]))
        .get();

    for (final cat in categories) {
      tags.add(['cat', cat.publicId, cat.name ?? '', cat.position?.toString() ?? '0']);
    }

    // Add channels — 18-element positional array for interop
    final channels = await (_db.select(_db.channels)
          ..where((c) => c.serverId.equals(server.id))
          ..orderBy([(c) => OrderingTerm.asc(c.position)]))
        .get();

    for (final ch in channels) {
      // Find category public ID
      String categoryPublicId = '';
      if (ch.categoryId != null) {
        final cat = categories.where((c) => c.id == ch.categoryId).firstOrNull;
        categoryPublicId = cat?.publicId ?? '';
      }

      // Find parent channel public ID (for nested voice channels)
      String parentPublicId = '';
      if (ch.parentChannelId != null) {
        final parent = channels.where((c) => c.id == ch.parentChannelId).firstOrNull;
        parentPublicId = parent?.publicId ?? '';
      }

      tags.add([
        'ch',
        ch.publicId,
        ch.name,
        ch.channelType == 1 ? 'voice' : 'text',
        (ch.position ?? 0).toString(),
        categoryPublicId,
        ch.topic ?? '',
        (ch.nsfw ?? false).toString(),
        ch.nostrGroupId ?? '$gid-${ch.publicId}',
        ch.permissionsOverrides ?? '',
        ch.encrypted.toString(),
        ch.channelPublicKey ?? '',
        '', // sidechatPublicId
        parentPublicId,
        (ch.voiceBitrate).toString(),
        (ch.voiceUserLimit).toString(),
        ch.videoEnabled.toString(),
        (ch.postOnly).toString(),
      ]);
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31751,
      tags: tags,
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
  }

  /// Publish Kind 31752 roles
  Future<void> publishRoles({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
  }) async {
    final gid = server.nostrGroupId ?? '';
    final tags = <List<String>>[
      ['d', 'inferno-roles-$gid'],
    ];

    final roles = await (_db.select(_db.roles)
          ..where((r) => r.serverId.equals(server.id))
          ..orderBy([(r) => OrderingTerm.desc(r.position)]))
        .get();

    for (final role in roles) {
      tags.add([
        'role',
        role.publicId,
        role.name ?? '',
        (role.position ?? 0).toString(),
        role.color ?? '#ffffff',
        role.permissions ?? '{}',
      ]);
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31752,
      tags: tags,
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
  }

  /// Publish Kind 31753 member event (announce ourselves to the server)
  Future<void> publishMember({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
  }) async {
    if (server.nostrGroupId == null) return;
    final baseId = server.nostrGroupId!;

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: [
        ['d', 'inferno-mbr-$baseId-${publicKeyHex.substring(0, 16)}'],
        ['p', publicKeyHex],
        ['server', server.nostrGroupId!],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
  }

  /// Publish Kind 31753 member removal event (leave server)
  /// Matches Rails: publish_server_state(:member, removed: true)
  Future<void> publishMemberRemoval({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
  }) async {
    if (server.nostrGroupId == null) return;
    final baseId = server.nostrGroupId!;

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: [
        ['d', 'inferno-mbr-$baseId-${publicKeyHex.substring(0, 16)}'],
        ['server', server.nostrGroupId!],
        ['p', publicKeyHex],
        ['removed', 'true'],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
  }
}
