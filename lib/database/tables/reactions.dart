import 'package:drift/drift.dart';

class Reactions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get messageId => integer()();
  IntColumn get userId => integer()();
  TextColumn get emoji => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {userId, messageId, emoji},
  ];
}
