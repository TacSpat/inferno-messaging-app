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

  /// Add a relay. Idempotent: `url` is unique, so a plain insert throws when
  /// the relay is already known, and callers merging a NIP-65 list are
  /// expected to re-offer relays they already have.
  Future<int> addRelay(String url) {
    return _db.into(_db.relayConnections).insert(
      RelayConnectionsCompanion.insert(
        url: url,
        status: const Value('active'),
        retryCount: const Value(0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      mode: InsertMode.insertOrIgnore,
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

  /// Seed the default relay set if any are missing.
  ///
  /// This only ever ADDS. It used to delete every relay outside the hardcoded
  /// default list on each launch, which ran at bootstrap and so silently
  /// discarded relays the user had added by hand as well as any learned from
  /// a NIP-65 relay list. Cross-device relay sync could never persist because
  /// the next launch wiped it. Removing a relay is an explicit user action —
  /// see removeRelay().
  Future<void> ensureDefaultRelays() async {
    const defaultRelays = [
      'wss://relay.damus.io',
      'wss://nos.lol',
      'wss://relay.snort.social',
    ];

    final existing = await _db.select(_db.relayConnections).get();
    final existingUrls = existing.map((r) => r.url).toSet();

    // Add missing defaults. Deliberately no removal pass — see the doc
    // comment above.
    for (final url in defaultRelays) {
      if (!existingUrls.contains(url)) {
        await addRelay(url);
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
