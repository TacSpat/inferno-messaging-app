import 'dart:convert';
import 'package:drift/drift.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import 'relay_config_service.dart';

class ServerPublishService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;
  final RelayConfigService _relayConfig;

  ServerPublishService(this._db, this._relayPool, this._relayConfig);

  Future<void> _logOutbound(nostr.NostrEvent signed, int kind, int serverId) async {
    if (signed.id == null) return;
    await _relayConfig.markEventProcessed(
      eventId: signed.id!,
      direction: 'outbound',
      kind: kind,
      pubkey: signed.pubkey,
      serverId: serverId,
      eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(signed.createdAt * 1000),
    );
  }

  /// Publish Kind 31750 server metadata
  /// Matches Rails NostrServerPublishJob#build_metadata_tags
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
      ['owner', publicKeyHex],
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

    // Welcome message settings
    if (server.welcomeChannelId != null) {
      final wCh = await (_db.select(_db.channels)
            ..where((c) => c.id.equals(server.welcomeChannelId!))
            ..limit(1))
          .getSingleOrNull();
      if (wCh != null) tags.add(['welcome_channel', wCh.nostrGroupId ?? '']);
    }
    tags.add(['welcome_message', server.welcomeMessageTemplate]);
    tags.add(['welcome_enabled', server.welcomeMessageEnabled.toString()]);

    // Visibility & classification
    tags.add(['discoverable', server.discoverable.toString()]);
    tags.add(['server_type', server.serverType]);
    tags.add(['age_restricted', server.ageRestricted.toString()]);
    tags.add(['voice_enabled', server.voiceEnabled.toString()]);

    // AFK channel settings
    if (server.afkChannelId != null) {
      final afkCh = await (_db.select(_db.channels)
            ..where((c) => c.id.equals(server.afkChannelId!))
            ..limit(1))
          .getSingleOrNull();
      if (afkCh != null) tags.add(['afk_channel', afkCh.publicId]);
    }
    tags.add(['afk_timeout', server.afkTimeout.toString()]);
    tags.add(['afk_action', server.afkAction]);

    // Voice providers
    final voiceProviders = await (_db.select(_db.serverVoiceProviders)
          ..where((v) => v.serverId.equals(server.id) & v.active.equals(true)))
        .get();
    for (final vp in voiceProviders) {
      if (vp.providerPubkey != null) tags.add(['voice_provider', vp.providerPubkey!]);
    }

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
    await _logOutbound(signed, 31750, server.id);
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
      ['server', gid],
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
    await _logOutbound(signed, 31751, server.id);
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
      ['server', gid],
    ];

    final roles = await (_db.select(_db.roles)
          ..where((r) => r.serverId.equals(server.id))
          ..orderBy([(r) => OrderingTerm.desc(r.position)]))
        .get();

    for (final role in roles) {
      // Must match Rails format exactly:
      // ['role', publicId, name, color, position, hoist, mentionable, permissions_json, role_type]
      tags.add([
        'role',
        role.publicId,
        role.name ?? '',
        role.color ?? '#99aab5',
        (role.position ?? 0).toString(),
        role.hoist.toString(),
        (role.mentionable ?? false).toString(),
        role.permissions ?? '{}',
        '', // role_type
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
    await _logOutbound(signed, 31752, server.id);
  }

  /// Publish Kind 31753 member event (announce ourselves to the server)
  /// Matches Rails NostrServerPublishJob#build_member_event — includes embedded profile data
  Future<void> publishMember({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
  }) async {
    if (server.nostrGroupId == null) return;
    final baseId = server.nostrGroupId!;

    final tags = <List<String>>[
      ['d', 'inferno-mbr-$baseId-${publicKeyHex.substring(0, 16)}'],
      ['p', publicKeyHex],
      ['server', server.nostrGroupId!],
    ];

    // Embed profile data in member event (matches Rails profile_* tags)
    final contact = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(publicKeyHex)))
        .getSingleOrNull();
    final member = await (_db.select(_db.remoteMembers)
          ..where((m) => m.pubkey.equals(publicKeyHex) & m.serverId.equals(server.id)))
        .getSingleOrNull();

    if (contact != null) {
      tags.add(['profile_name', contact.username ?? '']);
      tags.add(['profile_display_name', contact.displayName ?? '']);
      tags.add(['profile_picture', contact.avatarUrl ?? '']);
      tags.add(['profile_banner', contact.bannerUrl ?? '']);
      tags.add(['profile_about', contact.bio ?? '']);
      tags.add(['profile_status', contact.status ?? '']);
      tags.add(['profile_status_emoji', contact.statusEmoji ?? '']);
    }
    tags.add(['profile_color', member?.profileColor ?? '']);
    tags.add(['profile_color_2', member?.profileColor2 ?? '']);

    // Include role assignments if we have them
    if (member != null) {
      final roleAssignments = await (_db.select(_db.remoteMembershipRoles)
            ..where((a) => a.remoteMemberId.equals(member.id)))
          .get();
      for (final ra in roleAssignments) {
        final role = await (_db.select(_db.roles)
              ..where((r) => r.id.equals(ra.roleId)))
            .getSingleOrNull();
        if (role != null) {
          tags.add(['role', role.publicId, role.name ?? '']);
        }
      }
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: tags,
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
    await _logOutbound(signed, 31753, server.id);
  }

  /// Publish Kind 31753 member removal event (kick / leave server)
  /// Matches Rails: publish_server_state(:member, removed: true)
  Future<void> publishMemberRemoval({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
    required String targetPubkey,
  }) async {
    if (server.nostrGroupId == null) return;
    final baseId = server.nostrGroupId!;

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: [
        ['d', 'inferno-mbr-$baseId-${targetPubkey.substring(0, 16)}'],
        ['server', server.nostrGroupId!],
        ['p', targetPubkey],
        ['removed', 'true'],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
    await _logOutbound(signed, 31753, server.id);
  }

  /// Publish Kind 31756 ban event
  Future<void> publishBan({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
    required String targetPubkey,
    String reason = '',
  }) async {
    if (server.nostrGroupId == null) return;
    final baseId = server.nostrGroupId!;

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31756,
      tags: [
        ['d', 'inferno-ban-$baseId-${targetPubkey.substring(0, 16)}'],
        ['server', server.nostrGroupId!],
        ['p', targetPubkey],
        ['reason', reason],
        ['banned_by', publicKeyHex],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
    await _logOutbound(signed, 31756, server.id);
  }

  /// Publish Kind 31756 unban event
  Future<void> publishUnban({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
    required String targetPubkey,
  }) async {
    if (server.nostrGroupId == null) return;
    final baseId = server.nostrGroupId!;

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31756,
      tags: [
        ['d', 'inferno-ban-$baseId-${targetPubkey.substring(0, 16)}'],
        ['server', server.nostrGroupId!],
        ['p', targetPubkey],
        ['unbanned', 'true'],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
    await _logOutbound(signed, 31756, server.id);
  }

  /// Publish Kind 31753 member event with updated roles
  Future<void> publishMemberRoleUpdate({
    required String privateKeyHex,
    required String publicKeyHex,
    required Server server,
    required String targetPubkey,
    required List<String> rolePublicIds,
  }) async {
    if (server.nostrGroupId == null) return;
    final baseId = server.nostrGroupId!;

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: [
        ['d', 'inferno-mbr-$baseId-${targetPubkey.substring(0, 16)}'],
        ['server', server.nostrGroupId!],
        ['p', targetPubkey],
        ['roles', ...rolePublicIds],
      ],
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
    await _logOutbound(signed, 31753, server.id);
  }
}
