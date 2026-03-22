import 'package:drift/drift.dart';

class Blocks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get blockerId => integer()();
  IntColumn get blockedId => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {blockerId, blockedId},
  ];
}
