import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database/database.dart';
import 'image_hasher.dart';
import 'nsfw_detector.dart';
import 'reputation_scorer.dart';

/// Orchestrates all content safety checks for incoming messages.
/// Called after message creation to decide if a message should be auto-hidden.
///
/// Filters (checked in order, first match wins):
///   0. CSAM hash — perceptual match against known CSAM hashes (always on)
///   1. NSFW detection — ONNX classifier flags explicit images
///   2. Unknown sender — not a friend or known contact (DMs only)
///   3. Report threshold — sender has N+ reports
///   4. Reputation score — weighted multi-signal score below threshold
///   5. Image hash — perceptual match against previously-flagged content
///
/// Plus text filters after stage 5:
///   Block links, phone numbers, ALL CAPS, spam chars, keyword filter
///
/// All auto-hides are reversible via safety settings (except CSAM).
class ContentSafetyService {
  final InfernoDatabase _db;

  ContentSafetyService(this._db);

  /// Run all enabled filters on a message. Returns true if auto-hidden.
  /// Call after message insert in DM and group message services.
  Future<bool> check(int messageId) async {
    final message = await (_db.select(_db.messages)
          ..where((m) => m.id.equals(messageId)))
        .getSingleOrNull();
    if (message == null || message.hiddenAt != null) return false;

    final settings = await _getSettings();

    // CSAM check is non-negotiable — runs even on own messages
    if (await _imageCsamMatch(message)) {
      await _autoHide(message, 'csam_match', settings);
      return true;
    }

    // NSFW check runs on all messages (including own) — if you post
    // explicit content in a non-NSFW channel, it should still be flagged
    if (await _nsfwImageMatch(message)) {
      await _autoHide(message, 'nsfw', settings);
      return true;
    }

    // Never filter own messages beyond CSAM + NSFW
    final localUser = await (_db.select(_db.users)..limit(1)).getSingleOrNull();
    if (localUser != null && message.nostrAuthorPubkey == localUser.nostrPublicKey) {
      return false;
    }

    // Stage 2: Unknown sender (DMs only)
    if (_isStandardProtection(settings) && await _unknownSender(message, settings)) {
      await _autoHide(message, 'unknown_sender', settings);
      return true;
    }

    // Stage 3: Report threshold
    if (_isStandardProtection(settings) && await _overReportThreshold(message, settings)) {
      await _autoHide(message, 'reported', settings);
      return true;
    }

    // Stage 4: Reputation
    if (_isStandardProtection(settings) && await _belowReputationThreshold(message, settings)) {
      await _autoHide(message, 'low_reputation', settings);
      return true;
    }

    // Stage 5: Image hash
    if (await _imageHashMatch(message, settings)) {
      await _autoHide(message, 'image_match', settings);
      return true;
    }

    // Text filters (standard protection only)
    if (_isStandardProtection(settings)) {
      final textReason = await _checkTextFilters(message, settings);
      if (textReason != null) {
        await _autoHide(message, textReason, settings);
        return true;
      }
    }

    // No filter triggered — proactively hash images for future matching
    if (settings.safetyImageHashEnabled) {
      _storeImageHashesAsync(message);
    }

    return false;
  }

  /// Unhide a message. Allowlists its content hashes. Blocks unhide for CSAM.
  Future<bool> unhide(int messageId) async {
    final message = await (_db.select(_db.messages)
          ..where((m) => m.id.equals(messageId)))
        .getSingleOrNull();
    if (message == null || message.hiddenAt == null) return false;

    // Block unhide for CSAM matches
    if (message.hiddenReason?.contains('csam') == true) return false;

    // Allowlist content hashes for this message
    await (_db.update(_db.contentHashes)
          ..where((c) => c.messageId.equals(messageId)))
        .write(const ContentHashesCompanion(allowlisted: Value(true)));

    // Clear hidden status
    await (_db.update(_db.messages)
          ..where((m) => m.id.equals(messageId)))
        .write(const MessagesCompanion(
      hiddenAt: Value(null),
      hiddenReason: Value(null),
    ));

    return true;
  }

  // ── Filter implementations ──

  /// Filter 0: CSAM hash matching (always on)
  Future<bool> _imageCsamMatch(Message message) async {
    if (message.fileUrls == null) return false;

    final hashes = await ImageHasher.hashMessageAttachments(message.fileUrls);
    if (hashes.isEmpty) return false;

    final csamEntries = await _db.select(_db.csamHashEntries).get();
    for (final h in hashes) {
      for (final csam in csamEntries) {
        if (csam.hashType == h.hashType &&
            ImageHasher.isSimilar(h.hashValue, csam.hashValue, threshold: 10)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Filter 1: NSFW image detection
  Future<bool> _nsfwImageMatch(Message message) async {
    if (!NsfwDetector.instance.available) return false;
    if (message.fileUrls == null) return false;
    return NsfwDetector.instance.anyExplicit(message.fileUrls);
  }

  /// Filter 2: Unknown sender (DMs only)
  Future<bool> _unknownSender(Message message, AppSetting settings) async {
    if (!settings.safetyHideUnknownSenders) return false;
    if (message.nostrAuthorPubkey == null) return false;
    // Only filter DMs, not channel messages
    if (message.channelId != null) return false;

    final contact = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(message.nostrAuthorPubkey!)))
        .getSingleOrNull();
    // Unknown = no contact record, or not a friend
    return contact == null || contact.friendshipStatus != 3;
  }

  /// Filter 3: Report threshold
  Future<bool> _overReportThreshold(Message message, AppSetting settings) async {
    final threshold = settings.safetyReportThreshold;
    if (threshold <= 0) return false;
    if (message.nostrAuthorPubkey == null) return false;

    final contactReport = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(message.nostrAuthorPubkey!)))
        .getSingleOrNull();
    final contactCount = contactReport?.reportCount ?? 0;

    final remoteMax = await (_db.selectOnly(_db.remoteMembers)
          ..addColumns([_db.remoteMembers.reportCount.max()])
          ..where(_db.remoteMembers.pubkey.equals(message.nostrAuthorPubkey!)))
        .map((row) => row.read(_db.remoteMembers.reportCount.max()))
        .getSingleOrNull();

    final maxReports = contactCount > (remoteMax ?? 0) ? contactCount : (remoteMax ?? 0);
    return maxReports >= threshold;
  }

  /// Filter 4: Reputation score
  Future<bool> _belowReputationThreshold(Message message, AppSetting settings) async {
    if (!settings.safetyReputationEnabled) return false;
    if (message.nostrAuthorPubkey == null) return false;

    final scorer = ReputationScorer(
      _db, message.nostrAuthorPubkey!,
      sensitivity: settings.safetyReputationSensitivity,
    );
    final score = await scorer.score();
    return score < settings.safetyReputationThreshold;
  }

  /// Filter 5: Image hash matching
  Future<bool> _imageHashMatch(Message message, AppSetting settings) async {
    if (!settings.safetyImageHashEnabled) return false;
    if (message.fileUrls == null) return false;

    final hashes = await ImageHasher.hashMessageAttachments(message.fileUrls);
    if (hashes.isEmpty) return false;

    final stored = await (_db.select(_db.contentHashes)
          ..where((c) => c.allowlisted.equals(false)))
        .get();

    for (final h in hashes) {
      for (final s in stored) {
        if (s.hashType == h.hashType &&
            ImageHasher.isSimilar(h.hashValue, s.hashValue, threshold: 10)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Text content filters
  Future<String?> _checkTextFilters(Message message, AppSetting settings) async {
    final content = message.content;
    if (content == null || content.isEmpty) return null;

    // Block links
    if (settings.safetyBlockLinks) {
      final urlRegex = RegExp(r'https?://[^\s]+', caseSensitive: false);
      if (urlRegex.hasMatch(content)) return 'blocked_link';
    }

    // Block phone numbers
    if (settings.safetyBlockPhoneNumbers) {
      final phoneRegex = RegExp(r'[\+]?[(]?[0-9]{1,4}[)]?[-\s\./0-9]{7,}');
      if (phoneRegex.hasMatch(content)) return 'blocked_phone';
    }

    // Block ALL CAPS (>80% uppercase, >10 chars)
    if (settings.safetyBlockAllCaps && content.length > 10) {
      final letters = content.replaceAll(RegExp(r'[^a-zA-Z]'), '');
      if (letters.isNotEmpty) {
        final upperRatio = letters.replaceAll(RegExp(r'[^A-Z]'), '').length / letters.length;
        if (upperRatio > 0.8) return 'blocked_caps';
      }
    }

    // Block spam chars (5+ consecutive identical non-alphanum)
    if (settings.safetyBlockSpamChars) {
      final spamRegex = RegExp(r'([^a-zA-Z0-9\s])\1{4,}');
      if (spamRegex.hasMatch(content)) return 'blocked_spam';
    }

    // Keyword filter
    if (settings.safetyKeywordFilter.isNotEmpty) {
      final keywords = settings.safetyKeywordFilter
          .split(',')
          .map((k) => k.trim().toLowerCase())
          .where((k) => k.isNotEmpty);
      final lower = content.toLowerCase();
      for (final keyword in keywords) {
        if (lower.contains(keyword)) return 'blocked_keyword';
      }
    }

    return null;
  }

  // ── Auto-hide logic ──

  Future<void> _autoHide(Message message, String reason, AppSetting settings) async {
    debugPrint('[ContentSafety] Auto-hiding message ${message.id} ($reason)');

    // Store image hashes before clearing fileUrls
    if (settings.safetyImageHashEnabled && message.fileUrls != null) {
      await _storeImageHashes(message);
    }

    // Record hidden attachments
    if (message.fileUrls != null) {
      try {
        final urls = jsonDecode(message.fileUrls!) as List<dynamic>;
        for (final url in urls) {
          final urlStr = url.toString();
          final filename = Uri.tryParse(urlStr)?.pathSegments.lastOrNull ?? urlStr;
          await _db.into(_db.hiddenAttachmentRecords).insert(
            HiddenAttachmentRecordsCompanion.insert(
              messageId: message.id,
              originalFilename: filename,
              purgedAt: Value(DateTime.now()),
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
        }
      } catch (_) {}
    }

    // Hide the message
    await (_db.update(_db.messages)
          ..where((m) => m.id.equals(message.id)))
        .write(MessagesCompanion(
      hiddenAt: Value(DateTime.now()),
      hiddenReason: Value('auto:$reason'),
      fileUrls: const Value(null), // purge file URLs
    ));

    // Increment author report count (except for unknown_sender)
    if (reason != 'unknown_sender' && message.nostrAuthorPubkey != null) {
      await _incrementReportCount(message.nostrAuthorPubkey!);
    }
  }

  Future<void> _incrementReportCount(String pubkey) async {
    final contact = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (contact != null) {
      await (_db.update(_db.contacts)
            ..where((c) => c.pubkey.equals(pubkey)))
          .write(ContactsCompanion(
        reportCount: Value(contact.reportCount + 1),
      ));
    }
  }

  // ── Image hash storage ──

  Future<void> _storeImageHashes(Message message) async {
    final hashes = await ImageHasher.hashMessageAttachments(message.fileUrls);
    for (final h in hashes) {
      // Check if hash already exists
      final existing = await (_db.select(_db.contentHashes)
            ..where((c) => c.hashValue.equals(h.hashValue) & c.hashType.equals(h.hashType)))
          .getSingleOrNull();
      if (existing == null) {
        await _db.into(_db.contentHashes).insert(ContentHashesCompanion.insert(
          hashValue: h.hashValue,
          hashType: Value(h.hashType),
          mediaType: Value(h.mediaType),
          originalFilename: Value(h.originalFilename),
          messageId: Value(message.id),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));
      }
    }
  }

  void _storeImageHashesAsync(Message message) {
    // Fire-and-forget background hash storage
    _storeImageHashes(message).catchError((e) {
      debugPrint('[ContentSafety] Background hash storage failed: $e');
    });
  }

  // ── Settings helpers ──

  Future<AppSetting> _getSettings() async {
    return await (_db.select(_db.appSettings)..limit(1)).getSingle();
  }

  bool _isStandardProtection(AppSetting settings) {
    return settings.safetyProtectionLevel == 'standard';
  }

  // ── Legacy convenience methods ──

  /// Check if a file's SHA-256 hash matches any known-bad hashes
  Future<bool> isHashBlocked(Uint8List fileBytes) async {
    final hash = sha256.convert(fileBytes).toString();
    final match = await (_db.select(_db.contentHashes)
          ..where((c) => c.hashValue.equals(hash) & c.allowlisted.equals(false)))
        .getSingleOrNull();
    return match != null;
  }

  /// Check message content against keyword filter
  Future<bool> containsBlockedKeywords(String content, String keywordFilter) async {
    if (keywordFilter.isEmpty) return false;
    final keywords = keywordFilter.split(',').map((k) => k.trim().toLowerCase()).where((k) => k.isNotEmpty);
    final lower = content.toLowerCase();
    for (final keyword in keywords) {
      if (lower.contains(keyword)) return true;
    }
    return false;
  }

  /// Store a content hash for future matching
  Future<void> recordHash({
    required String hashValue,
    required String hashType,
    int? messageId,
    String? mediaType,
    String source = 'local',
  }) async {
    await _db.into(_db.contentHashes).insert(ContentHashesCompanion.insert(
      hashValue: hashValue,
      hashType: Value(hashType),
      messageId: Value(messageId),
      mediaType: Value(mediaType),
      source: Value(source),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }
}
