import 'package:drift/drift.dart';

class Conversations extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get kind => integer().withDefault(const Constant(0))();  // 0=direct, 1=group_chat
  TextColumn get name => text().nullable()();
  TextColumn get counterpartyPubkey => text().nullable()();
  TextColumn get counterpartyDisplayName => text().nullable()();
  TextColumn get iconUrl => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
