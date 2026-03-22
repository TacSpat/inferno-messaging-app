import 'package:drift/drift.dart';

class Messages extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  TextColumn get content => text().nullable()();
  IntColumn get channelId => integer().nullable()();
  IntColumn get conversationId => integer().nullable()();
  IntColumn get userId => integer().nullable()();
  IntColumn get parentId => integer().nullable()();
  BoolColumn get pinned => boolean().nullable()();
  BoolColumn get isSticker => boolean().withDefault(const Constant(false))();
  BoolColumn get spoiler => boolean().withDefault(const Constant(false))();
  BoolColumn get systemMessage => boolean().withDefault(const Constant(false))();
  TextColumn get renderedContentCached => text().nullable()();
  DateTimeColumn get editedAt => dateTime().nullable()();
  DateTimeColumn get hiddenAt => dateTime().nullable()();
  IntColumn get hiddenById => integer().nullable()();
  TextColumn get hiddenReason => text().nullable()();
  TextColumn get nostrAuthorPubkey => text().nullable()();
  TextColumn get nostrEventId => text().nullable().unique()();
  TextColumn get nostrEventJson => text().nullable()();
  TextColumn get fileUrls => text().nullable()();  // JSON array of Blossom URLs
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
