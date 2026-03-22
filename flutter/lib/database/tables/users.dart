import 'package:drift/drift.dart';

class Users extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  TextColumn get username => text()();
  TextColumn get discriminator => text().withLength(max: 4).withDefault(const Constant('0000'))();
  TextColumn get displayName => text().nullable()();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get bio => text().nullable()();
  TextColumn get status => text().nullable()();
  TextColumn get statusEmoji => text().nullable()();
  TextColumn get profileColor => text().nullable()();
  TextColumn get profileColor2 => text().nullable()();
  IntColumn get bannerOffsetY => integer().nullable()();
  BoolColumn get avatarNsfw => boolean().withDefault(const Constant(false))();
  BoolColumn get bannerNsfw => boolean().withDefault(const Constant(false))();
  IntColumn get onlineState => integer().withDefault(const Constant(0))();
  TextColumn get theme => text().withDefault(const Constant('inferno'))();
  TextColumn get nostrPublicKey => text().nullable().unique()();
  TextColumn get nostrEncryptedPrivateKey => text().nullable()();
  DateTimeColumn get nostrContactsPublishedAt => dateTime().nullable()();
  DateTimeColumn get nostrProfilePublishedAt => dateTime().nullable()();
  TextColumn get livekitUrl => text().nullable()();
  TextColumn get livekitApiKey => text().nullable()();
  TextColumn get livekitApiSecretEnc => text().nullable()();
  BoolColumn get livekitVerified => boolean().withDefault(const Constant(false))();
  DateTimeColumn get livekitVerifiedAt => dateTime().nullable()();
  TextColumn get notificationPreferences => text().withDefault(const Constant('{}'))();
  TextColumn get voiceSettings => text().withDefault(const Constant('{}'))();
  BoolColumn get instanceAdmin => boolean().withDefault(const Constant(false))();
  TextColumn get avatarUrl => text().nullable()();
  TextColumn get bannerUrl => text().nullable()();
  DateTimeColumn get onlineAt => dateTime().nullable()();
  DateTimeColumn get tutorialCompletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
