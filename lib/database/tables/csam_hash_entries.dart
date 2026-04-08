import 'package:drift/drift.dart';

class CsamHashEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hashValue => text()();
  TextColumn get hashType => text().withDefault(const Constant('dhash'))();
  TextColumn get listSource => text()();
  DateTimeColumn get addedAt => dateTime()();
}
