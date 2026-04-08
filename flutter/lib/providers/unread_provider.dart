import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import 'database_provider.dart';

/// Local user ID constant — channel_reads is local-only, single-user DB.
const _localUserId = 0;

/// ID of the channel currently being viewed (suppress its badge).
final activeChannelIdProvider = StateProvider<int?>((ref) => null);

/// ID of the conversation currently being viewed (suppress its badge).
final activeConversationIdProvider = StateProvider<int?>((ref) => null);

/// Reactive unread count for a channel.
/// Returns 0 if the channel is currently active (being viewed).
final channelUnreadCountProvider = StreamProvider.family<int, int>((ref, channelId) {
  final db = ref.watch(databaseProvider);
  final activeId = ref.watch(activeChannelIdProvider);
  if (activeId == channelId) return Stream.value(0);

  return db.messagesDao.watchChannelRead(channelId, _localUserId).asyncExpand((read) {
    if (read != null) {
      return db.messagesDao.watchUnreadCount(channelId, read.lastReadAt);
    } else {
      return db.messagesDao.watchHasMessages(channelId).map((has) => has ? 1 : 0);
    }
  });
});

/// Reactive unread count for a DM conversation.
/// Returns 0 if the conversation is currently active.
final conversationUnreadCountProvider = StreamProvider.family<int, int>((ref, convId) {
  final db = ref.watch(databaseProvider);
  final activeId = ref.watch(activeConversationIdProvider);
  if (activeId == convId) return Stream.value(0);

  return (db.select(db.conversations)..where((c) => c.id.equals(convId)))
      .watchSingleOrNull()
      .asyncExpand((conv) {
    if (conv == null) return Stream.value(0);
    if (conv.lastReadAt != null) {
      return db.messagesDao.watchConversationUnreadCount(convId, conv.lastReadAt!);
    } else {
      return db.messagesDao.watchConversationHasMessages(convId).map((has) => has ? 1 : 0);
    }
  });
});

/// Whether ANY text channel in a server has unreads.
final serverHasUnreadsProvider = StreamProvider.family<bool, int>((ref, serverId) {
  final db = ref.watch(databaseProvider);
  final activeChannelId = ref.watch(activeChannelIdProvider);

  return (db.select(db.channels)
        ..where((c) => c.serverId.equals(serverId))
        ..where((c) => c.channelType.equals(0)))
      .watch()
      .asyncExpand((channels) {
    if (channels.isEmpty) return Stream.value(false);

    // Create a combined stream: listen to all channel unread streams
    final controller = StreamController<bool>();
    final unreads = <int, bool>{};
    final subs = <StreamSubscription>[];

    for (final ch in channels) {
      if (ch.id == activeChannelId) {
        unreads[ch.id] = false;
        continue;
      }
      final sub = db.messagesDao.watchChannelRead(ch.id, _localUserId).asyncExpand((read) {
        if (read != null) {
          return db.messagesDao.watchUnreadCount(ch.id, read.lastReadAt)
              .map((count) => count > 0);
        } else {
          return db.messagesDao.watchHasMessages(ch.id);
        }
      }).listen((hasUnread) {
        unreads[ch.id] = hasUnread;
        controller.add(unreads.values.any((v) => v));
      });
      subs.add(sub);
    }

    controller.onCancel = () {
      for (final s in subs) {
        s.cancel();
      }
    };

    return controller.stream;
  });
});

/// The constant user ID used for channel_reads.
int get localUserId => _localUserId;
