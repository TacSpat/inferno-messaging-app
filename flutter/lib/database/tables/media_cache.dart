import 'package:drift/drift.dart';

/// Persists resolved media dimensions so image/GIF/video placeholders
/// maintain correct size across restarts — prevents scroll jump on load.
class MediaCache extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get url => text().unique()();
  RealColumn get width => real()();
  RealColumn get height => real()();
  DateTimeColumn get createdAt => dateTime()();
}
