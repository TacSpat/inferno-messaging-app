import 'dart:math';

import 'package:drift/drift.dart';
import '../database/database.dart';

/// Computes a trust score (0-100) for a Nostr pubkey based on weighted signals.
///
/// Signals and base weights:
///   Your own hides of their messages:   -15 each (cap -45)
///   report_count from community:        -3 each (cap -30)
///   Banned from servers you're in:      -10 each (cap -30)
///   Is your friend:                     +20
///   Has been seen before (known):       +5
///
/// Sensitivity multipliers (applied to penalties only):
///   relaxed:   0.5x
///   moderate:  1.0x
///   strict:    1.5x
class ReputationScorer {
  static const _baseScore = 100;

  static const _ownHideWeight = -15;
  static const _ownHideCap = -45;

  static const _reportWeight = -3;
  static const _reportCap = -30;

  static const _banWeight = -10;
  static const _banCap = -30;

  static const _friendBonus = 20;
  static const _knownBonus = 5;

  static const _sensitivityMultipliers = {
    'relaxed': 0.5,
    'moderate': 1.0,
    'strict': 1.5,
  };

  final InfernoDatabase _db;
  final String pubkey;
  final String sensitivity;

  ReputationScorer(this._db, this.pubkey, {this.sensitivity = 'moderate'});

  double get _multiplier => _sensitivityMultipliers[sensitivity] ?? 1.0;

  /// Compute the reputation score (0-100).
  Future<int> score() async {
    final bd = await breakdown();
    final raw = _baseScore + bd.penalties + bd.bonuses;
    return raw.clamp(0, 100);
  }

  /// Compute detailed breakdown of all signals.
  Future<ReputationBreakdown> breakdown() async {
    // Look up contact
    final contact = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .getSingleOrNull();

    // 1. Own hides of their messages
    final ownHides = await (_db.selectOnly(_db.messages)
          ..addColumns([_db.messages.id.count()])
          ..where(_db.messages.nostrAuthorPubkey.equals(pubkey) &
              _db.messages.hiddenAt.isNotNull()))
        .map((row) => row.read(_db.messages.id.count()) ?? 0)
        .getSingle();
    final ownHidePenalty = max(ownHides * _ownHideWeight, _ownHideCap);

    // 2. Community report count
    final contactReports = contact?.reportCount ?? 0;
    final remoteReportsQuery = await (_db.selectOnly(_db.remoteMembers)
          ..addColumns([_db.remoteMembers.reportCount.max()])
          ..where(_db.remoteMembers.pubkey.equals(pubkey)))
        .map((row) => row.read(_db.remoteMembers.reportCount.max()))
        .getSingleOrNull();
    final remoteReports = remoteReportsQuery ?? 0;
    final totalReports = max(contactReports, remoteReports);
    final reportPenalty = max(totalReports * _reportWeight, _reportCap);

    // 3. Bans from servers user is in
    final banCount = await _countBans();
    final banPenalty = max(banCount * _banWeight, _banCap);

    // Apply sensitivity multiplier to penalties
    final totalPenalties = ((ownHidePenalty + reportPenalty + banPenalty) * _multiplier).round();

    // Bonuses (not affected by sensitivity)
    int bonuses = 0;
    final isFriend = contact?.friendshipStatus == 3; // accepted
    if (isFriend) bonuses += _friendBonus;
    if (contact != null) bonuses += _knownBonus;

    return ReputationBreakdown(
      ownHides: ownHides,
      ownHidePenalty: ownHidePenalty,
      reportCount: totalReports,
      reportPenalty: reportPenalty,
      banCount: banCount,
      banPenalty: banPenalty,
      isFriend: isFriend,
      isKnown: contact != null,
      penalties: totalPenalties,
      bonuses: bonuses,
    );
  }

  Future<int> _countBans() async {
    // Bans table uses userId — look up user by nostrPublicKey first
    final bannedUser = await (_db.select(_db.users)
          ..where((u) => u.nostrPublicKey.equals(pubkey)))
        .getSingleOrNull();
    if (bannedUser == null) return 0;

    final bans = await (_db.selectOnly(_db.bans)
          ..addColumns([_db.bans.id.count()])
          ..where(_db.bans.userId.equals(bannedUser.id)))
        .map((row) => row.read(_db.bans.id.count()) ?? 0)
        .getSingle();
    return bans;
  }
}

class ReputationBreakdown {
  final int ownHides;
  final int ownHidePenalty;
  final int reportCount;
  final int reportPenalty;
  final int banCount;
  final int banPenalty;
  final bool isFriend;
  final bool isKnown;
  final int penalties;
  final int bonuses;

  const ReputationBreakdown({
    required this.ownHides,
    required this.ownHidePenalty,
    required this.reportCount,
    required this.reportPenalty,
    required this.banCount,
    required this.banPenalty,
    required this.isFriend,
    required this.isKnown,
    required this.penalties,
    required this.bonuses,
  });
}
