import 'package:drift/drift.dart';

class ServerFolders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get userId => integer()();
  TextColumn get name => text().withLength(max: 50).withDefault(const Constant('Folder'))();
  IntColumn get position => integer().withDefault(const Constant(0))();
  BoolColumn get collapsed => boolean().withDefault(const Constant(true))();
  TextColumn get color => text().withDefault(const Constant('#4f545c'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
