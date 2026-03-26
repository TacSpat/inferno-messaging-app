import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/role_service.dart';
import '../services/member_service.dart';
import '../services/permission_service.dart';
import 'database_provider.dart';
import 'auth_provider.dart';

final roleServiceProvider = Provider<RoleService>((ref) {
  final db = ref.watch(databaseProvider);
  return RoleService(db);
});

final memberServiceProvider = Provider<MemberService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return MemberService(db, pool);
});

final serverRolesProvider = StreamProvider.family<List<Role>, int>((ref, serverId) {
  final roleService = ref.watch(roleServiceProvider);
  return roleService.watchServerRoles(serverId);
});

final serverBansProvider = StreamProvider.family<List<Ban>, int>((ref, serverId) {
  final memberService = ref.watch(memberServiceProvider);
  return memberService.watchBans(serverId);
});

final serverMembershipsProvider = StreamProvider.family<List<ServerMembership>, int>((ref, serverId) {
  final memberService = ref.watch(memberServiceProvider);
  return memberService.watchMemberships(serverId);
});

final permissionServiceProvider = Provider<PermissionService>((ref) {
  final db = ref.watch(databaseProvider);
  return PermissionService(db);
});
