import 'package:drift/drift.dart';

class Contacts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get pubkey => text().unique()();
  TextColumn get username => text().nullable()();
  TextColumn get displayName => text().nullable()();
  TextColumn get petname => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get bannerUrl => text().nullable()();
  TextColumn get bio => text().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get statusEmoji => text().nullable()();
  TextColumn get nip05 => text().nullable()();
  TextColumn get relayUrl => text().nullable()();
  IntColumn get friendshipStatus => integer().withDefault(const Constant(0))();
  IntColumn get reportCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get lastSeenAt => dateTime().nullable()();
  DateTimeColumn get profileFetchedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
