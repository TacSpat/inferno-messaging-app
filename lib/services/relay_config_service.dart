import 'package:drift/drift.dart';
import '../database/database.dart';

class RelayConfigService {
  final InfernoDatabase _db;

  RelayConfigService(this._db);

  /// Get all active relay URLs
  Future<List<String>> getActiveRelayUrls() async {
    final rows = await (_db.select(_db.relayConnections)
          ..where((r) => r.status.equals('active')))
        .get();
    return rows.map((r) => r.url).toList();
  }

  /// Get all relay connections
  Future<List<RelayConnection>> getAllRelays() {
    return _db.select(_db.relayConnections).get();
  }

  /// Watch all relay connections (reactive)
  Stream<List<RelayConnection>> watchAllRelays() {
    return _db.select(_db.relayConnections).watch();
  }

  /// Add a new relay
  Future<int> addRelay(String url) {
    return _db.into(_db.relayConnections).insert(
      RelayConnectionsCompanion.insert(
        url: url,
        status: const Value('active'),
        retryCount: const Value(0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Remove a relay by URL
  Future<int> removeRelay(String url) {
    return (_db.delete(_db.relayConnections)
          ..where((r) => r.url.equals(url)))
        .go();
  }

  /// Update relay status
  Future<void> updateRelayStatus(String url, String status, {String? errorMessage}) async {
    final now = DateTime.now();
    await (_db.update(_db.relayConnections)
          ..where((r) => r.url.equals(url)))
        .write(RelayConnectionsCompanion(
      status: Value(status),
      lastErrorMessage: Value(errorMessage),
      lastErrorAt: status == 'error' ? Value(now) : const Value.absent(),
      lastConnectedAt: status == 'active' ? Value(now) : const Value.absent(),
      updatedAt: Value(now),
    ));
  }

  /// Increment retry count for a relay
  Future<void> incrementRetryCount(String url) async {
    final relay = await (_db.select(_db.relayConnections)
          ..where((r) => r.url.equals(url)))
        .getSingleOrNull();
    if (relay == null) return;

    await (_db.update(_db.relayConnections)
          ..where((r) => r.url.equals(url)))
        .write(RelayConnectionsCompanion(
      retryCount: Value(relay.retryCount + 1),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Reset retry count on successful connection
  Future<void> resetRetryCount(String url) async {
    await (_db.update(_db.relayConnections)
          ..where((r) => r.url.equals(url)))
        .write(RelayConnectionsCompanion(
      retryCount: const Value(0),
      lastConnectedAt: Value(DateTime.now()),
      status: const Value('active'),
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Ensure default relays exist and remove stale ones
  Future<void> ensureDefaultRelays() async {
    const defaultRelays = [
      'wss://relay.damus.io',
      'wss://nos.lol',
      'wss://relay.snort.social',
    ];

    final existing = await _db.select(_db.relayConnections).get();
    final existingUrls = existing.map((r) => r.url).toSet();

    // Add missing defaults
    for (final url in defaultRelays) {
      if (!existingUrls.contains(url)) {
        await addRelay(url);
      }
    }

    // Remove relays not in the default set (cleanup stale entries)
    for (final relay in existing) {
      if (!defaultRelays.contains(relay.url)) {
        await (_db.delete(_db.relayConnections)..where((r) => r.url.equals(relay.url))).go();
      }
    }
  }

  /// Check if a relay event ID has been processed (deduplication)
  Future<bool> isEventProcessed(String eventId) async {
    final row = await (_db.select(_db.nostrEventLogs)
          ..where((e) => e.eventId.equals(eventId)))
        .getSingleOrNull();
    return row != null;
  }

  /// Mark an event as processed
  Future<void> markEventProcessed({
    required String eventId,
    required String direction,
    required int kind,
    required String pubkey,
    int? channelId,
    int? serverId,
    int? messageId,
    DateTime? eventCreatedAt,
  }) async {
    await _db.into(_db.nostrEventLogs).insert(
      NostrEventLogsCompanion.insert(
        eventId: eventId,
        direction: direction,
        kind: kind,
        pubkey: pubkey,
        channelId: Value(channelId),
        serverId: Value(serverId),
        messageId: Value(messageId),
        eventCreatedAt: Value(eventCreatedAt ?? DateTime.now()),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      onConflict: DoNothing(),
    );
  }

  /// Batch check which event IDs have already been processed
  Future<Set<String>> filterProcessedEvents(List<String> eventIds) async {
    if (eventIds.isEmpty) return {};
    final rows = await (_db.select(_db.nostrEventLogs)
          ..where((e) => e.eventId.isIn(eventIds)))
        .get();
    return rows.map((r) => r.eventId).toSet();
  }
}
