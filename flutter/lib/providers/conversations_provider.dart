import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/dm_service.dart';
import '../services/contact_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

final dmServiceProvider = Provider<DmService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return DmService(db, pool);
});

final contactServiceProvider = Provider<ContactService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return ContactService(db, pool);
});

final conversationsStreamProvider = StreamProvider<List<Conversation>>((ref) {
  final db = ref.watch(databaseProvider);
  return (db.select(db.conversations)
        ..orderBy([(c) => OrderingTerm.desc(c.updatedAt)]))
      .watch();
});

final friendsStreamProvider = StreamProvider<List<Contact>>((ref) {
  final contactService = ref.watch(contactServiceProvider);
  return contactService.watchFriends();
});

final pendingRequestsStreamProvider = StreamProvider<List<Contact>>((ref) {
  final contactService = ref.watch(contactServiceProvider);
  return contactService.watchPendingIncoming();
});

final blockedContactsStreamProvider = StreamProvider<List<Contact>>((ref) {
  final contactService = ref.watch(contactServiceProvider);
  return contactService.watchBlocked();
});

final conversationMessagesProvider = StreamProvider.family<List<Message>, int>((ref, conversationId) {
  final db = ref.watch(databaseProvider);
  return db.messagesDao.watchConversationMessages(conversationId);
});
