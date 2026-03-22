import 'package:drift/drift.dart';

class RemoteMembers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().nullable().unique()();
  IntColumn get serverId => integer()();
  TextColumn get pubkey => text()();
  TextColumn get username => text().nullable()();
  TextColumn get displayName => text().nullable()();
  TextColumn get nickname => text().nullable()();
  TextColumn get bio => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get bannerUrl => text().nullable()();
  TextColumn get profileColor => text().nullable()();
  TextColumn get profileColor2 => text().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get statusEmoji => text().nullable()();
  TextColumn get nip05 => text().nullable()();
  IntColumn get onlineState => integer().withDefault(const Constant(0))();
  IntColumn get reportCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();
  DateTimeColumn get joinedAt => dateTime().nullable()();
  DateTimeColumn get profileFetchedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {serverId, pubkey},
  ];
}
