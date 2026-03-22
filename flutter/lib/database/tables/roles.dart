import 'package:drift/drift.dart';

class Roles extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get serverId => integer()();
  TextColumn get name => text().nullable()();
  IntColumn get position => integer().nullable()();
  TextColumn get color => text().nullable()();
  BoolColumn get hoist => boolean().withDefault(const Constant(false))();
  BoolColumn get mentionable => boolean().nullable()();
  BoolColumn get selfAssignable => boolean().withDefault(const Constant(false))();
  TextColumn get roleType => text().nullable()();
  TextColumn get permissions => text().nullable()();  // JSON
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
