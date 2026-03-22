import 'package:drift/drift.dart';

class ServerVoiceProviders extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();
  IntColumn get userId => integer().nullable()();
  TextColumn get providerPubkey => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  IntColumn get position => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
