import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/server_sync_service.dart';
import '../services/server_publish_service.dart';
import '../services/group_message_service.dart';
import '../services/invite_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

final serverSyncServiceProvider = Provider<ServerSyncService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return ServerSyncService(db, pool);
});

final serverPublishServiceProvider = Provider<ServerPublishService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return ServerPublishService(db, pool);
});

final groupMessageServiceProvider = Provider<GroupMessageService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return GroupMessageService(db, pool);
});

final inviteServiceProvider = Provider<InviteService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return InviteService(db, pool);
});

final serversStreamProvider = StreamProvider<List<Server>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.select(db.servers).watch();
});

final serverChannelsProvider = StreamProvider.family<List<Channel>, int>((ref, serverId) {
  final db = ref.watch(databaseProvider);
  return db.serversDao.watchServerChannels(serverId);
});

final channelMessagesProvider = StreamProvider.family<List<Message>, int>((ref, channelId) {
  final db = ref.watch(databaseProvider);
  return db.messagesDao.watchChannelMessages(channelId);
});
