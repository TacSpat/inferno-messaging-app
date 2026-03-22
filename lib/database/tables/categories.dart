import 'package:drift/drift.dart';

class Categories extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get serverId => integer()();
  TextColumn get name => text().nullable()();
  IntColumn get position => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
