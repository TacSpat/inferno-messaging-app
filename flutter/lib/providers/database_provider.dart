import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';

final databaseProvider = Provider<InfernoDatabase>((ref) {
  final db = InfernoDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final messagesDaoProvider = Provider((ref) => ref.watch(databaseProvider).messagesDao);
final serversDaoProvider = Provider((ref) => ref.watch(databaseProvider).serversDao);
final contactsDaoProvider = Provider((ref) => ref.watch(databaseProvider).contactsDao);
