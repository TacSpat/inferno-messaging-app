import 'package:drift/drift.dart';

class VoiceStates extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get userId => integer()();
  IntColumn get serverId => integer()();
  IntColumn get channelId => integer()();
  TextColumn get sessionId => text().unique()();
  BoolColumn get selfMute => boolean().withDefault(const Constant(false))();
  BoolColumn get selfDeaf => boolean().withDefault(const Constant(false))();
  BoolColumn get serverMute => boolean().withDefault(const Constant(false))();
  BoolColumn get serverDeaf => boolean().withDefault(const Constant(false))();
  BoolColumn get screenShareOn => boolean().withDefault(const Constant(false))();
  BoolColumn get videoOn => boolean().withDefault(const Constant(false))();
  BoolColumn get broadcasting => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
