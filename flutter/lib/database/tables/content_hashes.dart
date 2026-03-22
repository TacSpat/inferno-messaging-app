import 'package:drift/drift.dart';

class ContentHashes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hashType => text().withDefault(const Constant('dhash'))();
  TextColumn get hashValue => text()();
  TextColumn get mediaType => text().nullable()();
  RealColumn get confidence => real().withDefault(const Constant(1.0))();
  BoolColumn get allowlisted => boolean().withDefault(const Constant(false))();
  IntColumn get reporterCount => integer().withDefault(const Constant(1))();
  TextColumn get reporterPubkeys => text().withDefault(const Constant('[]'))();  // JSON
  TextColumn get nostrEventIds => text().withDefault(const Constant('[]'))();  // JSON
  IntColumn get messageId => integer().nullable()();
  TextColumn get originalFilename => text().nullable()();
  TextColumn get source => text().withDefault(const Constant('local'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
