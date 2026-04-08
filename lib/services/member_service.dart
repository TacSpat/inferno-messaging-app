import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../database/database.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../nostr/relay_pool.dart';
import 'relay_config_service.dart';

class MemberService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;
  final RelayConfigService _relayConfig;

  MemberService(this._db, this._relayPool, this._relayConfig);

  /// Assign a role to a server membership
  Future<void> assignRole(int membershipId, int roleId) async {
    final now = DateTime.now();
    await _db.into(_db.membershipRoles).insert(
      MembershipRolesCompanion.insert(
        serverMembershipId: membershipId,
        roleId: roleId,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Remove a role from a membership
  Future<void> removeRole(int membershipId, int roleId) async {
    await (_db.delete(_db.membershipRoles)
          ..where((mr) => mr.serverMembershipId.equals(membershipId) & mr.roleId.equals(roleId)))
        .go();
  }

  /// Get roles for a membership
  Future<List<Role>> getMemberRoles(int membershipId) async {
    final roleLinks = await (_db.select(_db.membershipRoles)
          ..where((mr) => mr.serverMembershipId.equals(membershipId)))
        .get();
    if (roleLinks.isEmpty) return [];
    final roleIds = roleLinks.map((r) => r.roleId).toList();
    return (_db.select(_db.roles)..where((r) => r.id.isIn(roleIds))).get();
  }

  /// Kick a member from a server
  Future<void> kickMember(int membershipId) async {
    await (_db.delete(_db.membershipRoles)
          ..where((mr) => mr.serverMembershipId.equals(membershipId)))
        .go();
    await (_db.delete(_db.serverMemberships)
          ..where((m) => m.id.equals(membershipId)))
        .go();
  }

  /// Ban a member
  Future<void> banMember({
    required int serverId,
    required int userId,
    required int bannedById,
    String? reason,
    String? privateKeyHex,
    String? publicKeyHex,
    String? nostrGroupId,
  }) async {
    final now = DateTime.now();
    await _db.into(_db.bans).insert(BansCompanion.insert(
      serverId: serverId,
      userId: userId,
      bannedById: bannedById,
      reason: Value(reason),
      createdAt: now,
      updatedAt: now,
    ));

    // Remove membership
    await (_db.delete(_db.serverMemberships)
          ..where((m) => m.userId.equals(userId) & m.serverId.equals(serverId)))
        .go();

    // Publish Kind 31756 ban event
    if (privateKeyHex != null && publicKeyHex != null && nostrGroupId != null) {
      final bannedUser = await (_db.select(_db.users)..where((u) => u.id.equals(userId))).getSingleOrNull();
      if (bannedUser?.nostrPublicKey != null) {
        final event = nostr.NostrEvent(
          pubkey: publicKeyHex,
          createdAt: nostr.NostrEvent.now(),
          kind: 31756,
          tags: [
            ['d', 'inferno-ban-$nostrGroupId-${bannedUser!.nostrPublicKey!.substring(0, 16)}'],
            ['p', bannedUser.nostrPublicKey!],
            if (reason != null) ['reason', reason],
          ],
          content: '',
        );
        final signer = NostrSigner(privateKeyHex: privateKeyHex);
        final signed = signer.sign(event);
        await _relayPool.publish(signed);
        if (signed.id != null) {
          await _relayConfig.markEventProcessed(
            eventId: signed.id!, direction: 'outbound',
            kind: 31756, pubkey: publicKeyHex, serverId: serverId,
            eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(signed.createdAt * 1000),
          );
        }
      }
    }
  }

  /// Unban a member
  Future<void> unbanMember(int serverId, int userId) async {
    await (_db.delete(_db.bans)
          ..where((b) => b.serverId.equals(serverId) & b.userId.equals(userId)))
        .go();
  }

  /// Timeout a member
  Future<void> timeoutMember(int membershipId, Duration duration, int timedOutById) async {
    await (_db.update(_db.serverMemberships)
          ..where((m) => m.id.equals(membershipId)))
        .write(ServerMembershipsCompanion(
      timedOutUntil: Value(DateTime.now().add(duration)),
      timedOutById: Value(timedOutById),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Remove timeout
  Future<void> removeTimeout(int membershipId) async {
    await (_db.update(_db.serverMemberships)
          ..where((m) => m.id.equals(membershipId)))
        .write(ServerMembershipsCompanion(
      timedOutUntil: const Value(null),
      timedOutById: const Value(null),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Watch bans for a server
  Stream<List<Ban>> watchBans(int serverId) {
    return (_db.select(_db.bans)..where((b) => b.serverId.equals(serverId))).watch();
  }

  /// Watch memberships for a server
  Stream<List<ServerMembership>> watchMemberships(int serverId) {
    return (_db.select(_db.serverMemberships)
          ..where((m) => m.serverId.equals(serverId)))
        .watch();
  }

  // --- Remote member moderation (used from member list sidebar) ---

  /// Kick a remote member: remove from DB, publish Kind 31753 + Kind 9001
  Future<void> kickRemoteMember({
    required int serverId,
    required String targetPubkey,
    required String privateKeyHex,
    required String publicKeyHex,
  }) async {
    final server = await (_db.select(_db.servers)..where((s) => s.id.equals(serverId))).getSingleOrNull();
    if (server == null) return;
    final nostrGroupId = server.nostrGroupId;

    // Remove role assignments
    final member = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(targetPubkey)))
        .getSingleOrNull();
    if (member != null) {
      await (_db.delete(_db.remoteMembershipRoles)
            ..where((mr) => mr.remoteMemberId.equals(member.id)))
          .go();
      await (_db.delete(_db.remoteMembers)..where((m) => m.id.equals(member.id))).go();
    }

    if (nostrGroupId == null) return;
    final signer = NostrSigner(privateKeyHex: privateKeyHex);

    // Publish Kind 31753 member event with removed flag
    final memberEvent = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: [
        ['d', 'inferno-mbr-$nostrGroupId-${targetPubkey.substring(0, 16)}'],
        ['server', nostrGroupId],
        ['p', targetPubkey],
        ['removed', 'true'],
      ],
      content: '',
    );
    final signedMember = signer.sign(memberEvent);
    await _relayPool.publish(signedMember);
    if (signedMember.id != null) {
      await _relayConfig.markEventProcessed(
        eventId: signedMember.id!, direction: 'outbound',
        kind: 31753, pubkey: publicKeyHex, serverId: serverId,
        eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(signedMember.createdAt * 1000),
      );
    }

    // Publish Kind 9001 remove-user to each channel in the server
    await _publishRemoveUserToChannels(serverId, nostrGroupId, targetPubkey, signer, publicKeyHex);

    debugPrint('[MemberService] Kicked remote member ${targetPubkey.substring(0, 12)}');
  }

  /// Ban a remote member: remove from DB, publish Kind 31756 + Kind 31753 + Kind 9001
  Future<void> banRemoteMember({
    required int serverId,
    required String targetPubkey,
    required String privateKeyHex,
    required String publicKeyHex,
    String? reason,
  }) async {
    final server = await (_db.select(_db.servers)..where((s) => s.id.equals(serverId))).getSingleOrNull();
    if (server == null) return;
    final nostrGroupId = server.nostrGroupId;

    // Remove role assignments and member record
    final member = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(targetPubkey)))
        .getSingleOrNull();
    if (member != null) {
      await (_db.delete(_db.remoteMembershipRoles)
            ..where((mr) => mr.remoteMemberId.equals(member.id)))
          .go();
      await (_db.delete(_db.remoteMembers)..where((m) => m.id.equals(member.id))).go();
    }

    if (nostrGroupId == null) return;
    final signer = NostrSigner(privateKeyHex: privateKeyHex);

    // Publish Kind 31756 ban event
    final banEvent = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31756,
      tags: [
        ['d', 'inferno-ban-$nostrGroupId-${targetPubkey.substring(0, 16)}'],
        ['server', nostrGroupId],
        ['p', targetPubkey],
        if (reason != null && reason.isNotEmpty) ['reason', reason],
        ['banned_by', publicKeyHex],
      ],
      content: '',
    );
    final signedBan = signer.sign(banEvent);
    await _relayPool.publish(signedBan);
    if (signedBan.id != null) {
      await _relayConfig.markEventProcessed(
        eventId: signedBan.id!, direction: 'outbound',
        kind: 31756, pubkey: publicKeyHex, serverId: serverId,
        eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(signedBan.createdAt * 1000),
      );
    }

    // Publish Kind 31753 member removed
    final memberEvent = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: [
        ['d', 'inferno-mbr-$nostrGroupId-${targetPubkey.substring(0, 16)}'],
        ['server', nostrGroupId],
        ['p', targetPubkey],
        ['removed', 'true'],
      ],
      content: '',
    );
    final signedMemberRemoval = signer.sign(memberEvent);
    await _relayPool.publish(signedMemberRemoval);
    if (signedMemberRemoval.id != null) {
      await _relayConfig.markEventProcessed(
        eventId: signedMemberRemoval.id!, direction: 'outbound',
        kind: 31753, pubkey: publicKeyHex, serverId: serverId,
        eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(signedMemberRemoval.createdAt * 1000),
      );
    }

    // Publish Kind 9001 remove-user to each channel
    await _publishRemoveUserToChannels(serverId, nostrGroupId, targetPubkey, signer, publicKeyHex);

    debugPrint('[MemberService] Banned remote member ${targetPubkey.substring(0, 12)}');
  }

  /// Timeout a remote member: publish Kind 31753 with timeout tags
  Future<void> timeoutRemoteMember({
    required int serverId,
    required String targetPubkey,
    required Duration duration,
    required String privateKeyHex,
    required String publicKeyHex,
  }) async {
    final server = await (_db.select(_db.servers)..where((s) => s.id.equals(serverId))).getSingleOrNull();
    if (server == null) return;
    final nostrGroupId = server.nostrGroupId;
    if (nostrGroupId == null) return;

    final until = DateTime.now().add(duration);
    final signer = NostrSigner(privateKeyHex: privateKeyHex);

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 31753,
      tags: [
        ['d', 'inferno-mbr-$nostrGroupId-${targetPubkey.substring(0, 16)}'],
        ['server', nostrGroupId],
        ['p', targetPubkey],
        ['timed_out_until', (until.millisecondsSinceEpoch ~/ 1000).toString()],
        ['timed_out_by', publicKeyHex],
      ],
      content: '',
    );
    final signedTimeout = signer.sign(event);
    await _relayPool.publish(signedTimeout);
    if (signedTimeout.id != null) {
      await _relayConfig.markEventProcessed(
        eventId: signedTimeout.id!, direction: 'outbound',
        kind: 31753, pubkey: publicKeyHex, serverId: serverId,
        eventCreatedAt: DateTime.fromMillisecondsSinceEpoch(signedTimeout.createdAt * 1000),
      );
    }

    debugPrint('[MemberService] Timed out remote member ${targetPubkey.substring(0, 12)} for ${duration.inMinutes}m');
  }

  /// Publish Kind 9001 (NIP-29 remove-user) to all channels in a server
  Future<void> _publishRemoveUserToChannels(
    int serverId,
    String nostrGroupId,
    String targetPubkey,
    NostrSigner signer,
    String publicKeyHex,
  ) async {
    final channels = await (_db.select(_db.channels)
          ..where((c) => c.serverId.equals(serverId)))
        .get();
    for (final ch in channels) {
      if (ch.nostrGroupId == null) continue;
      final event = nostr.NostrEvent(
        pubkey: publicKeyHex,
        createdAt: nostr.NostrEvent.now(),
        kind: 9001,
        tags: [
          ['h', ch.nostrGroupId!],
          ['p', targetPubkey],
        ],
        content: '',
      );
      await _relayPool.publish(signer.sign(event));
    }
  }
}
