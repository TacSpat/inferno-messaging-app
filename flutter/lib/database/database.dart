import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

// Table imports
import 'tables/users.dart';
import 'tables/servers.dart';
import 'tables/channels.dart';
import 'tables/categories.dart';
import 'tables/messages.dart';
import 'tables/conversations.dart';
import 'tables/conversation_participants.dart';
import 'tables/contacts.dart';
import 'tables/roles.dart';
import 'tables/server_memberships.dart';
import 'tables/membership_roles.dart';
import 'tables/remote_members.dart';
import 'tables/remote_membership_roles.dart';
import 'tables/invites.dart';
import 'tables/bans.dart';
import 'tables/blocks.dart';
import 'tables/reactions.dart';
import 'tables/channel_reads.dart';
import 'tables/notifications.dart';
import 'tables/server_emojis.dart';
import 'tables/server_stickers.dart';
import 'tables/server_folders.dart';
import 'tables/voice_states.dart';
import 'tables/calls.dart';
import 'tables/call_participants.dart';
import 'tables/nostr_event_logs.dart';
import 'tables/nostr_events.dart';
import 'tables/relay_connections.dart';
import 'tables/server_voice_providers.dart';
import 'tables/app_settings.dart';
import 'tables/content_hashes.dart';
import 'tables/gif_collections.dart';
import 'tables/gif_favorites.dart';

// DAO imports
import 'daos/messages_dao.dart';
import 'daos/servers_dao.dart';
import 'daos/contacts_dao.dart';

part 'database.g.dart';

@DriftDatabase(
  tables: [
    Users,
    Servers,
    Channels,
    Categories,
    Messages,
    Conversations,
    ConversationParticipants,
    Contacts,
    Roles,
    ServerMemberships,
    MembershipRoles,
    RemoteMembers,
    RemoteMembershipRoles,
    Invites,
    Bans,
    Blocks,
    Reactions,
    ChannelReads,
    Notifications,
    ServerEmojis,
    ServerStickers,
    ServerFolders,
    VoiceStates,
    Calls,
    CallParticipants,
    NostrEventLogs,
    NostrEvents,
    RelayConnections,
    ServerVoiceProviders,
    AppSettings,
    ContentHashes,
    GifCollections,
    GifFavorites,
  ],
  daos: [
    MessagesDao,
    ServersDao,
    ContactsDao,
  ],
)
class InfernoDatabase extends _$InfernoDatabase {
  InfernoDatabase() : super(_openConnection());

  InfernoDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
        // Insert default app settings row
        await into(appSettings).insert(AppSettingsCompanion.insert(
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));
      },
    );
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dbFolder = await getApplicationDocumentsDirectory();
    final file = File(p.join(dbFolder.path, 'inferno.db'));
    return NativeDatabase.createInBackground(file);
  });
}
