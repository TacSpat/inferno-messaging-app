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
import 'tables/media_cache.dart';
import 'tables/csam_hash_entries.dart';
import 'tables/hidden_attachment_records.dart';
import 'tables/emoji_cache.dart';

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
    MediaCache,
    CsamHashEntries,
    HiddenAttachmentRecords,
    EmojiCache,
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
  int get schemaVersion => 8;

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
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          await m.addColumn(channels, channels.lastBackfilledAt);
          await m.addColumn(conversations, conversations.lastBackfilledAt);
        }
        if (from < 3) {
          await m.createTable(mediaCache);
        }
        if (from < 4) {
          await m.addColumn(serverEmojis, serverEmojis.creatorPubkey);
          await m.addColumn(serverStickers, serverStickers.creatorPubkey);
        }
        if (from < 5) {
          await m.addColumn(reactions, reactions.reactorPubkey);
        }
        if (from < 6) {
          await m.addColumn(conversations, conversations.lastReadAt);
        }
        if (from < 7) {
          await m.createTable(csamHashEntries);
          await m.createTable(hiddenAttachmentRecords);
          await m.addColumn(appSettings, appSettings.safetyProtectionLevel);
          await m.addColumn(appSettings, appSettings.safetySharedHashesEnabled);
          await m.addColumn(appSettings, appSettings.safetyPublishHashes);
          await m.addColumn(appSettings, appSettings.safetyBlockPhoneNumbers);
          await m.addColumn(appSettings, appSettings.safetyBlockAllCaps);
          await m.addColumn(appSettings, appSettings.safetyBlockSpamChars);
          await m.addColumn(appSettings, appSettings.safetyReportThreshold);
          await m.addColumn(appSettings, appSettings.safetyReputationEnabled);
          await m.addColumn(appSettings, appSettings.safetyReputationSensitivity);
          await m.addColumn(appSettings, appSettings.safetyReputationThreshold);
          await m.addColumn(appSettings, appSettings.safetySharedHashMinReporters);
          await m.addColumn(appSettings, appSettings.safetySharedHashTrustFriends);
        }
        if (from < 8) {
          await m.addColumn(messages, messages.customEmojiUrls);
          await m.createTable(emojiCache);
        }
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
