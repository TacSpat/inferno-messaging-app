import 'package:drift/drift.dart';

class ConversationParticipants extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get conversationId => integer()();
  IntColumn get userId => integer().nullable()();
  IntColumn get contactId => integer().nullable()();
  BoolColumn get accepted => boolean().withDefault(const Constant(false))();
  BoolColumn get muted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get lastReadAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
