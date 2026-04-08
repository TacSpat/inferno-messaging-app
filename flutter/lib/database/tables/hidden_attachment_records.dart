import 'package:drift/drift.dart';

class HiddenAttachmentRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get messageId => integer()();
  TextColumn get originalFilename => text()();
  TextColumn get contentType => text().nullable()();
  IntColumn get byteSize => integer().nullable()();
  TextColumn get checksum => text().nullable()();
  DateTimeColumn get purgedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
