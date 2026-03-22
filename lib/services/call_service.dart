import 'package:drift/drift.dart';
import '../database/database.dart';

class CallService {
  final InfernoDatabase _db;

  CallService(this._db);

  /// Initiate a call in a conversation
  Future<Call> initiateCall({
    required int conversationId,
    required int initiatedById,
    required String livekitRoomName,
  }) async {
    final now = DateTime.now();
    final publicId = now.microsecondsSinceEpoch.toRadixString(36).padLeft(12, '0').substring(0, 12);

    final id = await _db.into(_db.calls).insert(CallsCompanion.insert(
      publicId: publicId,
      conversationId: conversationId,
      initiatedById: initiatedById,
      status: const Value('ringing'),
      livekitRoomName: Value(livekitRoomName),
      startedAt: Value(now),
      createdAt: now,
      updatedAt: now,
    ));

    // Add initiator as participant
    await _db.into(_db.callParticipants).insert(CallParticipantsCompanion.insert(
      callId: id,
      userId: initiatedById,
      joinedAt: Value(now),
      createdAt: now,
      updatedAt: now,
    ));

    return (_db.select(_db.calls)..where((c) => c.id.equals(id))).getSingle();
  }

  /// Accept a call
  Future<void> acceptCall(int callId, int userId) async {
    final now = DateTime.now();
    await (_db.update(_db.calls)..where((c) => c.id.equals(callId)))
        .write(CallsCompanion(
      status: const Value('active'),
      updatedAt: Value(now),
    ));

    await _db.into(_db.callParticipants).insert(CallParticipantsCompanion.insert(
      callId: callId,
      userId: userId,
      joinedAt: Value(now),
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// Decline a call
  Future<void> declineCall(int callId) async {
    await (_db.update(_db.calls)..where((c) => c.id.equals(callId)))
        .write(CallsCompanion(
      status: const Value('declined'),
      endedAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Hang up (leave a call)
  Future<void> hangup(int callId, int userId) async {
    final now = DateTime.now();
    // Mark participant as left
    final participant = await (_db.select(_db.callParticipants)
          ..where((p) => p.callId.equals(callId) & p.userId.equals(userId)))
        .getSingleOrNull();

    if (participant != null) {
      final duration = participant.joinedAt != null
          ? now.difference(participant.joinedAt!).inSeconds
          : 0;
      await (_db.update(_db.callParticipants)..where((p) => p.id.equals(participant.id)))
          .write(CallParticipantsCompanion(
        leftAt: Value(now),
        durationSeconds: Value(duration),
        updatedAt: Value(now),
      ));
    }

    // Check if all participants have left
    final remaining = await (_db.select(_db.callParticipants)
          ..where((p) => p.callId.equals(callId) & p.leftAt.isNull()))
        .get();

    if (remaining.isEmpty) {
      await (_db.update(_db.calls)..where((c) => c.id.equals(callId)))
          .write(CallsCompanion(
        status: const Value('ended'),
        endedAt: Value(now),
        updatedAt: Value(now),
      ));
    }
  }

  /// Get active call for a conversation
  Future<Call?> getActiveCall(int conversationId) {
    return (_db.select(_db.calls)
          ..where((c) => c.conversationId.equals(conversationId) &
              (c.status.equals('ringing') | c.status.equals('active'))))
        .getSingleOrNull();
  }

  /// Watch active call for a conversation
  Stream<Call?> watchActiveCall(int conversationId) {
    return (_db.select(_db.calls)
          ..where((c) => c.conversationId.equals(conversationId) &
              (c.status.equals('ringing') | c.status.equals('active'))))
        .watchSingleOrNull();
  }
}
