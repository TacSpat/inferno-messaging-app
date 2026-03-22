import 'package:drift/drift.dart';

class RelayConnections extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get url => text().unique()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  DateTimeColumn get lastConnectedAt => dateTime().nullable()();
  DateTimeColumn get lastErrorAt => dateTime().nullable()();
  TextColumn get lastErrorMessage => text().nullable()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
