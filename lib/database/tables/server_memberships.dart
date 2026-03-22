import 'package:drift/drift.dart';

class ServerMemberships extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get userId => integer()();
  IntColumn get serverId => integer()();
  TextColumn get nickname => text().nullable()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  BoolColumn get onboardingCompleted => boolean().withDefault(const Constant(false))();
  IntColumn get serverFolderId => integer().nullable()();
  DateTimeColumn get timedOutUntil => dateTime().nullable()();
  IntColumn get timedOutById => integer().nullable()();
  DateTimeColumn get joinedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
