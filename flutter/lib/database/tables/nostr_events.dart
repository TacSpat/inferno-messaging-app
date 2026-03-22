import 'package:drift/drift.dart';

class NostrEvents extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get eventId => text().unique()();
  IntColumn get kind => integer()();
  TextColumn get pubkey => text()();
  TextColumn get content => text().nullable()();
  TextColumn get tags => text().nullable()();  // JSON
  TextColumn get sig => text()();
  DateTimeColumn get eventCreatedAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
