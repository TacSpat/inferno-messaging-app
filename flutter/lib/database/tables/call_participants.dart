import 'package:drift/drift.dart';

class CallParticipants extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get callId => integer()();
  IntColumn get userId => integer()();
  DateTimeColumn get joinedAt => dateTime().nullable()();
  DateTimeColumn get leftAt => dateTime().nullable()();
  IntColumn get durationSeconds => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {callId, userId},
  ];
}
