import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';

/// Fetches shared content hashes from Nostr relays via NIP-56 report events.
///
/// Kind 1984 events with ["x"] tags contain reported content hashes.
/// These are aggregated into the local content_hashes table with confidence
/// scoring. When confidence is high enough, hashes are auto-promoted to
/// csam_hash_entries for mandatory blocking.
class SharedHashService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;
  Timer? _periodicTimer;

  static const _confidenceThreshold = 5.0;
  static const _fetchIntervalMinutes = 60;

  SharedHashService(this._db, this._relayPool);

  /// Start periodic fetching of shared hashes.
  void start() {
    // Initial fetch
    fetchSharedHashes();
    // Periodic refresh
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(
      const Duration(minutes: _fetchIntervalMinutes),
      (_) => fetchSharedHashes(),
    );
  }

  void stop() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  /// Fetch kind 1984 report events from relays and process hash tags.
  Future<void> fetchSharedHashes() async {
    final settings = await (_db.select(_db.appSettings)..limit(1)).getSingle();
    if (!settings.safetySharedHashesEnabled) return;

    final minReporters = settings.safetySharedHashMinReporters;
    final trustFriends = settings.safetySharedHashTrustFriends;

    debugPrint('[SharedHash] Fetching shared hashes from relays...');

    try {
      // Fetch kind 1984 report events with hash tags
      final filter = NostrFilter(kinds: [1984], limit: 500);
      final nostrEvents = await _relayPool.fetch(filter, timeout: const Duration(seconds: 30));

      // Convert to maps for processing
      final events = nostrEvents.map((e) => e.toJson()).toList();

      int processed = 0;
      for (final event in events) {
        try {
          await _processReportEvent(event, trustFriends);
          processed++;
        } catch (e) {
          debugPrint('[SharedHash] Failed to process event: $e');
        }
      }

      if (processed > 0) {
        debugPrint('[SharedHash] Processed $processed report events');
        await _promoteHighConfidenceHashes(minReporters);
      }
    } catch (e) {
      debugPrint('[SharedHash] Fetch failed: $e');
    }
  }

  /// Process a single kind 1984 report event.
  Future<void> _processReportEvent(Map<String, dynamic> event, bool trustFriends) async {
    final tags = (event['tags'] as List<dynamic>?) ?? [];
    final reporterPubkey = event['pubkey'] as String?;
    if (reporterPubkey == null) return;

    for (final tag in tags) {
      if (tag is! List || tag.length < 2) continue;
      final tagName = tag[0].toString();

      // "x" tags contain content hashes
      if (tagName != 'x') continue;

      final hashValue = tag[1].toString();
      final hashType = tag.length > 2 ? tag[2].toString() : 'sha256';

      // Calculate confidence weight — friends are weighted higher
      double weight = 1.0;
      if (trustFriends) {
        final contact = await (_db.select(_db.contacts)
              ..where((c) => c.pubkey.equals(reporterPubkey)))
            .getSingleOrNull();
        if (contact != null && contact.friendshipStatus == 3) {
          weight = 2.0; // friend reporters count double
        }
      }

      await _upsertContentHash(hashValue, hashType, reporterPubkey, weight, event['id'] as String?);
    }
  }

  /// Upsert a content hash from a shared report.
  Future<void> _upsertContentHash(
    String hashValue, String hashType, String reporterPubkey,
    double weight, String? eventId,
  ) async {
    final existing = await (_db.select(_db.contentHashes)
          ..where((c) => c.hashValue.equals(hashValue) & c.hashType.equals(hashType)))
        .getSingleOrNull();

    if (existing != null) {
      // Update existing — add reporter, increment count and confidence
      List<String> reporters;
      try {
        reporters = (jsonDecode(existing.reporterPubkeys) as List<dynamic>).cast<String>();
      } catch (_) {
        reporters = [];
      }
      if (reporters.contains(reporterPubkey)) return; // already counted
      reporters.add(reporterPubkey);

      List<String> eventIds;
      try {
        eventIds = (jsonDecode(existing.nostrEventIds) as List<dynamic>).cast<String>();
      } catch (_) {
        eventIds = [];
      }
      if (eventId != null) eventIds.add(eventId);

      await (_db.update(_db.contentHashes)
            ..where((c) => c.id.equals(existing.id)))
          .write(ContentHashesCompanion(
        reporterCount: Value(existing.reporterCount + 1),
        confidence: Value(existing.confidence + weight),
        reporterPubkeys: Value(jsonEncode(reporters)),
        nostrEventIds: Value(jsonEncode(eventIds)),
        source: const Value('shared'),
        updatedAt: Value(DateTime.now()),
      ));
    } else {
      // Insert new
      await _db.into(_db.contentHashes).insert(ContentHashesCompanion.insert(
        hashValue: hashValue,
        hashType: Value(hashType),
        confidence: Value(weight),
        reporterCount: Value(1),
        reporterPubkeys: Value(jsonEncode([reporterPubkey])),
        nostrEventIds: Value(eventId != null ? jsonEncode([eventId]) : '[]'),
        source: Value('shared'),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
    }
  }

  /// Auto-promote high-confidence shared hashes to csam_hash_entries.
  Future<void> _promoteHighConfidenceHashes(int minReporters) async {
    final candidates = await (_db.select(_db.contentHashes)
          ..where((c) =>
              c.source.equals('shared') &
              c.confidence.isBiggerOrEqualValue(_confidenceThreshold) &
              c.reporterCount.isBiggerOrEqualValue(minReporters) &
              c.allowlisted.equals(false)))
        .get();

    for (final hash in candidates) {
      // Check if already in csam_hash_entries
      final existing = await (_db.select(_db.csamHashEntries)
            ..where((c) => c.hashValue.equals(hash.hashValue) & c.hashType.equals(hash.hashType)))
          .getSingleOrNull();
      if (existing != null) continue;

      await _db.into(_db.csamHashEntries).insert(CsamHashEntriesCompanion.insert(
        hashValue: hash.hashValue,
        hashType: Value(hash.hashType),
        listSource: 'shared_promotion',
        addedAt: DateTime.now(),
      ));
      debugPrint('[SharedHash] Promoted hash ${hash.hashValue} to CSAM entries (confidence: ${hash.confidence})');
    }
  }

  void dispose() {
    stop();
  }
}
