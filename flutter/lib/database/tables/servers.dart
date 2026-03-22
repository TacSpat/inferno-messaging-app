import 'package:drift/drift.dart';

class Servers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get ownerId => integer()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get serverType => text().withDefault(const Constant('community'))();
  TextColumn get nostrGroupId => text().nullable()();
  TextColumn get relayUrls => text().nullable()();  // JSON
  TextColumn get remoteOwnerPubkeys => text().withDefault(const Constant('[]'))();  // JSON
  IntColumn get welcomeChannelId => integer().nullable()();
  IntColumn get afkChannelId => integer().nullable()();
  BoolColumn get voiceEnabled => boolean().withDefault(const Constant(false))();
  IntColumn get afkTimeout => integer().withDefault(const Constant(5))();
  TextColumn get afkAction => text().withDefault(const Constant('move'))();
  BoolColumn get welcomeMessageEnabled => boolean().withDefault(const Constant(true))();
  TextColumn get welcomeMessageTemplate => text().withDefault(const Constant('Welcome to the server, {user}!'))();
  BoolColumn get onboardingEnabled => boolean().withDefault(const Constant(false))();
  TextColumn get onboardingRules => text().nullable()();
  TextColumn get onboardingDefaultChannelIds => text().withDefault(const Constant('[]'))();  // JSON
  TextColumn get onboardingSelfAssignableRoleIds => text().withDefault(const Constant('[]'))();  // JSON
  BoolColumn get ageRestricted => boolean().withDefault(const Constant(false))();
  BoolColumn get discoverable => boolean().withDefault(const Constant(false))();
  BoolColumn get iconNsfw => boolean().withDefault(const Constant(false))();
  BoolColumn get bannerNsfw => boolean().withDefault(const Constant(false))();
  TextColumn get iconUrl => text().nullable()();
  TextColumn get bannerUrl => text().nullable()();
  TextColumn get inviteCode => text().nullable().unique()();
  DateTimeColumn get lastSyncedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
