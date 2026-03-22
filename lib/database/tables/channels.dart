import 'package:drift/drift.dart';

class Channels extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get serverId => integer()();
  TextColumn get name => text()();
  IntColumn get channelType => integer()();
  IntColumn get position => integer().nullable()();
  IntColumn get categoryId => integer().nullable()();
  IntColumn get parentChannelId => integer().nullable()();
  TextColumn get topic => text().nullable()();
  BoolColumn get nsfw => boolean().nullable()();
  BoolColumn get postOnly => boolean().withDefault(const Constant(false))();
  TextColumn get nostrGroupId => text().nullable()();
  TextColumn get nostrRelayUrl => text().nullable()();
  TextColumn get nostrRelayUrls => text().nullable()();  // JSON
  BoolColumn get shared => boolean().withDefault(const Constant(false))();
  BoolColumn get encrypted => boolean().withDefault(const Constant(false))();
  TextColumn get channelPublicKey => text().nullable()();
  TextColumn get encryptedChannelPrivateKey => text().nullable()();
  TextColumn get permissionsOverrides => text().nullable()();  // JSON
  IntColumn get currentVoiceProviderId => integer().nullable()();
  IntColumn get voiceBitrate => integer().withDefault(const Constant(64000))();
  IntColumn get voiceUserLimit => integer().withDefault(const Constant(0))();
  BoolColumn get videoEnabled => boolean().withDefault(const Constant(false))();
  IntColumn get sidechatChannelId => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
