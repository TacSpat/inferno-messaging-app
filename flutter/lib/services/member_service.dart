import 'package:drift/drift.dart';
import '../database/database.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../nostr/relay_pool.dart';

class MemberService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  MemberService(this._db, this._relayPool);

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
}
