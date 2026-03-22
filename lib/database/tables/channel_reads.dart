import 'package:drift/drift.dart';

class ChannelReads extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get channelId => integer()();
  IntColumn get userId => integer()();
  DateTimeColumn get lastReadAt => dateTime()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {userId, channelId},
  ];
}
