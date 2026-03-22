import 'package:drift/drift.dart';

class Bans extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();
  IntColumn get userId => integer()();
  IntColumn get bannedById => integer()();
  TextColumn get reason => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {serverId, userId},
  ];
}
