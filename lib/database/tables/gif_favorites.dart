import 'package:drift/drift.dart';

class GifFavorites extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get userId => integer()();
  IntColumn get gifCollectionId => integer()();
  TextColumn get tenorGifId => text()();
  TextColumn get tenorUrl => text()();
  TextColumn get previewUrl => text()();
  TextColumn get gifUrl => text()();
  TextColumn get description => text().nullable()();
  IntColumn get position => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
