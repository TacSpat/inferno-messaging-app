import 'dart:convert';
import 'package:drift/drift.dart';
import '../database/database.dart';
import '../models/permission.dart';

/// Checks permissions for the current user against a server's role hierarchy.
/// Matches Rails: ServerMembership#has_permission? — owner > admin > roles > @everyone
class PermissionService {
  final InfernoDatabase _db;

  PermissionService(this._db);

  /// Check if a user (by pubkey) has a specific permission in a server.
  /// Walks: server owner > admin role > assigned roles > @everyone role
  Future<bool> hasPermission(int serverId, String userPubkey, Permission permission) async {
    // 1. Server owner bypasses all checks
    final server = await (_db.select(_db.servers)..where((s) => s.id.equals(serverId))).getSingleOrNull();
    if (server == null) return false;

    // Check if user is the server owner (owner published the metadata event)
    // For now, check if user created the server (ownerId = 1 for local user)
    final users = await _db.select(_db.users).get();
    if (users.isNotEmpty && users.first.nostrPublicKey == userPubkey && server.ownerId == users.first.id) {
      return true;
    }

    // 2. Find the remote member record for this user
    final member = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(userPubkey)))
        .getSingleOrNull();

    // 3. Check @everyone role (applies to all members)
    final everyoneRole = await (_db.select(_db.roles)
          ..where((r) => r.serverId.equals(serverId) & r.name.equals('@everyone')))
        .getSingleOrNull();
    if (everyoneRole != null && PermissionChecker.hasPermission(everyoneRole.permissions, permission)) {
      return true;
    }

    // 4. Check member's assigned roles
    if (member != null) {
      final memberRoles = await (_db.select(_db.remoteMembershipRoles)
            ..where((r) => r.remoteMemberId.equals(member.id)))
          .get();
      if (memberRoles.isNotEmpty) {
        final roleIds = memberRoles.map((r) => r.roleId).toList();
        final roles = await (_db.select(_db.roles)..where((r) => r.id.isIn(roleIds))).get();
        for (final role in roles) {
          if (PermissionChecker.hasPermission(role.permissions, permission)) return true;
        }
      }
    }

    return permission.defaultValue;
  }

  /// Get the display color for a member in a server.
  /// Matches Rails: walk roles by position desc, skip owner, return first non-gray color.
  Future<String> getDisplayColor(int serverId, String userPubkey) async {
    final member = await (_db.select(_db.remoteMembers)
          ..where((m) => m.serverId.equals(serverId) & m.pubkey.equals(userPubkey)))
        .getSingleOrNull();
    if (member == null) return '#ffffff';

    final memberRoleLinks = await (_db.select(_db.remoteMembershipRoles)
          ..where((r) => r.remoteMemberId.equals(member.id)))
        .get();
    if (memberRoleLinks.isEmpty) return '#ffffff';

    final roleIds = memberRoleLinks.map((r) => r.roleId).toList();
    final roles = await (_db.select(_db.roles)
          ..where((r) => r.id.isIn(roleIds))
          ..orderBy([(r) => OrderingTerm.desc(r.position)]))
        .get();

    for (final role in roles) {
      // Skip owner role
      if (role.permissions != null) {
        try {
          final perms = json.decode(role.permissions!) as Map<String, dynamic>;
          if (perms['owner'] == true) continue;
        } catch (_) {}
      }
      // Return first non-default-gray color
      if (role.color != null && role.color!.isNotEmpty && role.color != '#99aab5') {
        return role.color!;
      }
    }

    return '#ffffff';
  }

  /// Check if current user can manage the server (admin or owner)
  Future<bool> canManageServer(int serverId, String userPubkey) async {
    return hasPermission(serverId, userPubkey, Permission.manageServer);
  }

  /// Check if current user can manage roles
  Future<bool> canManageRoles(int serverId, String userPubkey) async {
    return hasPermission(serverId, userPubkey, Permission.manageRoles);
  }

  /// Check if current user can kick members
  Future<bool> canKickMembers(int serverId, String userPubkey) async {
    return hasPermission(serverId, userPubkey, Permission.kickMembers);
  }

  /// Check if current user can ban members
  Future<bool> canBanMembers(int serverId, String userPubkey) async {
    return hasPermission(serverId, userPubkey, Permission.banMembers);
  }
}
