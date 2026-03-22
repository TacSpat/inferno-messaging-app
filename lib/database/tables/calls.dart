import 'package:drift/drift.dart';

class Calls extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get conversationId => integer()();
  IntColumn get initiatedById => integer()();
  TextColumn get status => text().withDefault(const Constant('ringing'))();
  TextColumn get livekitRoomName => text().nullable()();
  DateTimeColumn get startedAt => dateTime().nullable()();
  DateTimeColumn get endedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
