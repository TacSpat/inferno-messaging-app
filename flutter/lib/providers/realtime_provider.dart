import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/reaction_service.dart';
import '../services/typing_service.dart';
import '../services/presence_service.dart';
import '../services/idle_detection_service.dart';
import '../services/notification_service.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

final reactionServiceProvider = Provider<ReactionService>((ref) {
  final db = ref.watch(databaseProvider);
  final pool = ref.watch(relayPoolProvider);
  return ReactionService(db, pool);
});

final typingServiceProvider = Provider<TypingService>((ref) {
  final pool = ref.watch(relayPoolProvider);
  final service = TypingService(pool);
  ref.onDispose(() => service.dispose());
  return service;
});

final presenceServiceProvider = Provider<PresenceService>((ref) {
  final pool = ref.watch(relayPoolProvider);
  final service = PresenceService(pool);
  ref.onDispose(() => service.dispose());
  return service;
});

final idleDetectionProvider = Provider<IdleDetectionService>((ref) {
  final presenceService = ref.watch(presenceServiceProvider);
  final service = IdleDetectionService(presenceService);
  ref.onDispose(() => service.dispose());
  return service;
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

/// Stream of typing users for a specific channel
final typingUsersProvider = StreamProvider.family<List<String>, String>((ref, channelGroupId) {
  final typingService = ref.watch(typingServiceProvider);
  return typingService.watchTyping(channelGroupId);
});
