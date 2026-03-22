import 'package:drift/drift.dart';

class Notifications extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get userId => integer()();
  IntColumn get serverId => integer()();
  IntColumn get channelId => integer()();
  IntColumn get messageId => integer()();
  IntColumn get notificationType => integer().withDefault(const Constant(0))();
  BoolColumn get read => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
