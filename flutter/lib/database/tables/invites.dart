import 'package:drift/drift.dart';

class Invites extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();
  IntColumn get creatorId => integer()();
  TextColumn get code => text().unique()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get expiresAt => dateTime().nullable()();
  IntColumn get maxUses => integer().nullable()();
  IntColumn get usesCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
