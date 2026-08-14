import 'package:drift/drift.dart';
import '../database.dart';
import '../tables/contacts.dart';
import '../tables/conversations.dart';
import '../tables/conversation_participants.dart';

part 'contacts_dao.g.dart';

@DriftAccessor(tables: [Contacts, Conversations, ConversationParticipants])
class ContactsDao extends DatabaseAccessor<InfernoDatabase>
    with _$ContactsDaoMixin {
  ContactsDao(super.db);

  // Watch all contacts (friends)
  Stream<List<Contact>> watchFriends() {
    return (select(contacts)
          ..where((c) => c.friendshipStatus.equals(3)) // accepted
          ..orderBy([(c) => OrderingTerm.asc(c.displayName)]))
        .watch();
  }

  // Watch pending incoming friend requests
  Stream<List<Contact>> watchPendingIncoming() {
    return (select(contacts)
          ..where((c) => c.friendshipStatus.equals(2))) // pending_incoming
        .watch();
  }

  // Watch pending outgoing friend requests
  Stream<List<Contact>> watchPendingOutgoing() {
    return (select(contacts)
          ..where((c) => c.friendshipStatus.equals(1))) // pending_outgoing
        .watch();
  }

  // Watch blocked contacts
  Stream<List<Contact>> watchBlocked() {
    return (select(contacts)
          ..where((c) => c.friendshipStatus.equals(5))) // blocked
        .watch();
  }

  // Get a contact by pubkey
  Future<Contact?> getByPubkey(String pubkey) {
    return (select(contacts)..where((c) => c.pubkey.equals(pubkey)))
        .getSingleOrNull();
  }

  // Watch all conversations
  Stream<List<Conversation>> watchConversations() {
    return (select(conversations)
          ..orderBy([(c) => OrderingTerm.desc(c.updatedAt)]))
        .watch();
  }

  // Get conversation by counterparty pubkey
  Future<Conversation?> getConversationByPubkey(String pubkey) {
    return (select(conversations)
          ..where((c) => c.counterpartyPubkey.equals(pubkey)))
        .getSingleOrNull();
  }

  // Get conversation by public ID
  Future<Conversation?> getConversationByPublicId(String publicId) {
    return (select(conversations)
          ..where((c) => c.publicId.equals(publicId)))
        .getSingleOrNull();
  }

  // Insert a conversation
  Future<int> insertConversation(ConversationsCompanion conversation) {
    return into(conversations).insert(conversation);
  }
}
