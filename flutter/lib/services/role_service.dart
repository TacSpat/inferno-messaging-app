import 'dart:convert';
import 'package:drift/drift.dart';
import '../database/database.dart';
import '../models/permission.dart';

class RoleService {
  final InfernoDatabase _db;

  RoleService(this._db);

  /// Create a new role
  Future<Role> createRole({
    required int serverId,
    required String name,
    int? position,
    String? color,
    String? permissionsJson,
  }) async {
    final publicId = _generatePublicId();
    final now = DateTime.now();
    final id = await _db.into(_db.roles).insert(RolesCompanion.insert(
      publicId: publicId,
      serverId: serverId,
      name: Value(name),
      position: Value(position ?? 1),
      color: Value(color ?? '#ffffff'),
      permissions: Value(permissionsJson ?? PermissionChecker.defaultPermissionsJson()),
      createdAt: now,
      updatedAt: now,
    ));
    return (_db.select(_db.roles)..where((r) => r.id.equals(id))).getSingle();
  }

  /// Update a role's permissions
  Future<void> updatePermissions(int roleId, Map<String, bool> permissions) async {
    await (_db.update(_db.roles)..where((r) => r.id.equals(roleId)))
        .write(RolesCompanion(
      permissions: Value(json.encode(permissions)),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Update a role's name/color/position
  Future<void> updateRole(int roleId, {String? name, String? color, int? position}) async {
    await (_db.update(_db.roles)..where((r) => r.id.equals(roleId)))
        .write(RolesCompanion(
      name: name != null ? Value(name) : const Value.absent(),
      color: color != null ? Value(color) : const Value.absent(),
      position: position != null ? Value(position) : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Delete a role
  Future<void> deleteRole(int roleId) async {
    // Remove role assignments first
    await (_db.delete(_db.membershipRoles)..where((mr) => mr.roleId.equals(roleId))).go();
    await (_db.delete(_db.remoteMembershipRoles)..where((mr) => mr.roleId.equals(roleId))).go();
    await (_db.delete(_db.roles)..where((r) => r.id.equals(roleId))).go();
  }

  /// Get all roles for a server
  Future<List<Role>> getServerRoles(int serverId) {
    return (_db.select(_db.roles)
          ..where((r) => r.serverId.equals(serverId))
          ..orderBy([(r) => OrderingTerm.desc(r.position)]))
        .get();
  }

  /// Watch roles for a server
  Stream<List<Role>> watchServerRoles(int serverId) {
    return (_db.select(_db.roles)
          ..where((r) => r.serverId.equals(serverId))
          ..orderBy([(r) => OrderingTerm.desc(r.position)]))
        .watch();
  }

  /// Create default roles for a new server (@everyone + Owner)
  Future<void> createDefaultRoles(int serverId) async {
    final now = DateTime.now();
    await _db.into(_db.roles).insert(RolesCompanion.insert(
      publicId: _generatePublicId(),
      serverId: serverId,
      name: const Value('@everyone'),
      position: const Value(0),
      permissions: Value(PermissionChecker.defaultPermissionsJson()),
      createdAt: now,
      updatedAt: now,
    ));
    await _db.into(_db.roles).insert(RolesCompanion.insert(
      publicId: _generatePublicId(),
      serverId: serverId,
      name: const Value('Owner'),
      position: const Value(100),
      permissions: Value(PermissionChecker.ownerPermissionsJson()),
      createdAt: now,
      updatedAt: now,
    ));
  }

  String _generatePublicId() {
    return DateTime.now().microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);
  }
}
