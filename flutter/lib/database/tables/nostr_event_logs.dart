import 'package:drift/drift.dart';

class NostrEventLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get eventId => text().unique()();
  TextColumn get direction => text()();
  IntColumn get kind => integer()();
  TextColumn get pubkey => text()();
  IntColumn get channelId => integer().nullable()();
  IntColumn get serverId => integer().nullable()();
  IntColumn get messageId => integer().nullable()();
  DateTimeColumn get eventCreatedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
