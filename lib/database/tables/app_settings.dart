import 'package:drift/drift.dart';

class AppSettings extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get pruningStrategy => text().withDefault(const Constant('none'))();
  IntColumn get messageRetentionDays => integer().withDefault(const Constant(0))();
  IntColumn get attachmentRetentionDays => integer().withDefault(const Constant(0))();
  IntColumn get maxDbSizeMb => integer().withDefault(const Constant(0))();
  IntColumn get maxCacheSizeMb => integer().withDefault(const Constant(500))();
  BoolColumn get keepPinnedMessages => boolean().withDefault(const Constant(true))();
  BoolColumn get pruneChannelMessages => boolean().withDefault(const Constant(true))();
  BoolColumn get pruneDmMessages => boolean().withDefault(const Constant(true))();
  BoolColumn get backfillEnabled => boolean().withDefault(const Constant(true))();
  IntColumn get backfillDays => integer().withDefault(const Constant(30))();
  TextColumn get blossomServerUrls => text().nullable()();  // JSON
  BoolColumn get safetyBlurNsfw => boolean().withDefault(const Constant(true))();
  BoolColumn get safetyBlockLinks => boolean().withDefault(const Constant(false))();
  BoolColumn get safetyHideUnknownSenders => boolean().withDefault(const Constant(false))();
  TextColumn get safetyKeywordFilter => text().withDefault(const Constant(''))();
  BoolColumn get safetyImageHashEnabled => boolean().withDefault(const Constant(true))();
  TextColumn get safetyProtectionLevel => text().withDefault(const Constant('standard'))();
  BoolColumn get safetySharedHashesEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get safetyPublishHashes => boolean().withDefault(const Constant(false))();
  BoolColumn get safetyBlockPhoneNumbers => boolean().withDefault(const Constant(false))();
  BoolColumn get safetyBlockAllCaps => boolean().withDefault(const Constant(false))();
  BoolColumn get safetyBlockSpamChars => boolean().withDefault(const Constant(false))();
  IntColumn get safetyReportThreshold => integer().withDefault(const Constant(3))();
  BoolColumn get safetyReputationEnabled => boolean().withDefault(const Constant(true))();
  TextColumn get safetyReputationSensitivity => text().withDefault(const Constant('moderate'))();
  IntColumn get safetyReputationThreshold => integer().withDefault(const Constant(40))();
  IntColumn get safetySharedHashMinReporters => integer().withDefault(const Constant(3))();
  BoolColumn get safetySharedHashTrustFriends => boolean().withDefault(const Constant(true))();
  IntColumn get maxUploadSizeMb => integer().withDefault(const Constant(25))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
