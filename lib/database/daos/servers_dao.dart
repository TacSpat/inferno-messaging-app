import 'package:drift/drift.dart';
import '../database.dart';
import '../tables/servers.dart';
import '../tables/channels.dart';
import '../tables/categories.dart';
import '../tables/server_memberships.dart';
import '../tables/roles.dart';
import '../tables/remote_members.dart';

part 'servers_dao.g.dart';

@DriftAccessor(tables: [Servers, Channels, Categories, ServerMemberships, Roles, RemoteMembers])
class ServersDao extends DatabaseAccessor<InfernoDatabase>
    with _$ServersDaoMixin {
  ServersDao(super.db);

  // Watch all servers the user belongs to
  Stream<List<Server>> watchUserServers(int userId) {
    final query = select(servers).join([
      innerJoin(serverMemberships,
          serverMemberships.serverId.equalsExp(servers.id)),
    ])
      ..where(serverMemberships.userId.equals(userId))
      ..orderBy([OrderingTerm.asc(serverMemberships.position)]);
    return query.watch().map((rows) => rows.map((r) => r.readTable(servers)).toList());
  }

  // Watch a single server by ID
  Stream<Server> watchServer(int id) {
    return (select(servers)..where((s) => s.id.equals(id))).watchSingle();
  }

  // Get a server by public ID
  Future<Server?> getByPublicId(String publicId) {
    return (select(servers)..where((s) => s.publicId.equals(publicId)))
        .getSingleOrNull();
  }

  // Get a server by Nostr group ID
  Future<Server?> getByNostrGroupId(String groupId) {
    return (select(servers)..where((s) => s.nostrGroupId.equals(groupId)))
        .getSingleOrNull();
  }

  // Watch channels for a server, ordered by position
  Stream<List<Channel>> watchServerChannels(int serverId) {
    return (select(channels)
          ..where((c) => c.serverId.equals(serverId))
          ..orderBy([(c) => OrderingTerm.asc(c.position)]))
        .watch();
  }

  // Watch categories for a server
  Stream<List<Category>> watchServerCategories(int serverId) {
    return (select(categories)
          ..where((c) => c.serverId.equals(serverId))
          ..orderBy([(c) => OrderingTerm.asc(c.position)]))
        .watch();
  }

  // Watch roles for a server
  Stream<List<Role>> watchServerRoles(int serverId) {
    return (select(roles)
          ..where((r) => r.serverId.equals(serverId))
          ..orderBy([(r) => OrderingTerm.desc(r.position)]))
        .watch();
  }

  // Watch remote members for a server
  Stream<List<RemoteMember>> watchRemoteMembers(int serverId) {
    return (select(remoteMembers)
          ..where((m) => m.serverId.equals(serverId)))
        .watch();
  }

  // Insert or update a server
  Future<int> upsertServer(ServersCompanion server) {
    return into(servers).insertOnConflictUpdate(server);
  }

  // Insert or update a channel
  Future<int> upsertChannel(ChannelsCompanion channel) {
    return into(channels).insertOnConflictUpdate(channel);
  }

  // Insert or update a category
  Future<int> upsertCategory(CategoriesCompanion category) {
    return into(categories).insertOnConflictUpdate(category);
  }

  // Get membership for a user in a server
  Future<ServerMembership?> getMembership(int userId, int serverId) {
    return (select(serverMemberships)
          ..where((m) => m.userId.equals(userId) & m.serverId.equals(serverId)))
        .getSingleOrNull();
  }

  // Get a channel by public ID
  Future<Channel?> getChannelByPublicId(String publicId) {
    return (select(channels)..where((c) => c.publicId.equals(publicId)))
        .getSingleOrNull();
  }

  // Get a channel by Nostr group ID
  Future<Channel?> getChannelByNostrGroupId(String groupId) {
    return (select(channels)..where((c) => c.nostrGroupId.equals(groupId)))
        .getSingleOrNull();
  }
}
