import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../services/dm_service.dart';
import '../services/contact_service.dart';
import '../utils/stream_debounce.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

/// Currently selected tab on the Contacts screen. Hoisted into a provider so
/// the unified header can host the tab pills and the list screen below stays
/// in sync.
final contactsTabProvider = StateProvider<String>((_) => 'all');

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
      .watch()
      .debounce(const Duration(milliseconds: 300));
});

final friendsStreamProvider = StreamProvider<List<Contact>>((ref) {
  final contactService = ref.watch(contactServiceProvider);
  return contactService.watchFriends();
});

final pendingRequestsStreamProvider = StreamProvider<List<Contact>>((ref) {
  final contactService = ref.watch(contactServiceProvider);
  return contactService.watchPendingIncoming();
});

final pendingOutgoingStreamProvider = StreamProvider<List<Contact>>((ref) {
  final contactService = ref.watch(contactServiceProvider);
  return contactService.watchPendingOutgoing();
});

/// Stream that emits on every remote voice state change — watch it to trigger rebuilds.
final voiceStateChangeProvider = StreamProvider<Map<String, dynamic>>((ref) {
  final dmService = ref.watch(dmServiceProvider);
  return dmService.voiceStateStream;
});

final blockedContactsStreamProvider = StreamProvider<List<Contact>>((ref) {
  final contactService = ref.watch(contactServiceProvider);
  return contactService.watchBlocked();
});

final conversationMessagesProvider = StreamProvider.family<List<Message>, int>((ref, conversationId) {
  final db = ref.watch(databaseProvider);
  return db.messagesDao.watchConversationMessages(conversationId);
});
