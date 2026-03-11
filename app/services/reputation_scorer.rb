# Computes a trust score (0-100) for a Nostr pubkey based on weighted signals.
#
# Design principles:
# - No single signal source can tank a score (caps per signal type)
# - Positive signals (friendship) offset negatives
# - Sensitivity is user-configurable (relaxed/moderate/strict)
# - Always reversible — scores inform auto-hide, never auto-ban
#
# Signals and base weights:
#   Your own hides of their messages:   -15 each (you trust yourself)
#   report_count from community:         -3 each (capped at -30, prevents brigading)
#   Banned from servers you're in:      -10 each (capped at -30)
#   Is your friend:                     +20 (trust boost)
#   Has been seen before (known):        +5
#
# Sensitivity multipliers (applied to penalties only):
#   relaxed:   0.5x  (tolerant, need strong evidence)
#   moderate:  1.0x  (balanced default)
#   strict:    1.5x  (cautious, low tolerance)
#
class ReputationScorer
  BASE_SCORE = 100

  SENSITIVITY_MULTIPLIERS = {
    "relaxed" => 0.5,
    "moderate" => 1.0,
    "strict" => 1.5
  }.freeze

  # Per-signal caps prevent any single signal type from dominating
  OWN_HIDE_WEIGHT = -15
  OWN_HIDE_CAP = -45 # max 3 hides before capped

  REPORT_WEIGHT = -3
  REPORT_CAP = -30 # 10 reports max effect

  BAN_WEIGHT = -10
  BAN_CAP = -30 # 3 bans max effect

  FRIEND_BONUS = 20
  KNOWN_BONUS = 5

  def initialize(pubkey, sensitivity: "moderate")
    @pubkey = pubkey
    @multiplier = SENSITIVITY_MULTIPLIERS[sensitivity] || 1.0
  end

  def score
    @score ||= compute_score
  end

  def breakdown
    @breakdown ||= compute_breakdown
  end

  private

  def compute_score
    bd = compute_breakdown
    raw = BASE_SCORE + bd[:penalties] + bd[:bonuses]
    raw.clamp(0, 100)
  end

  def compute_breakdown
    contact = Contact.find_by(pubkey: @pubkey)

    # --- Penalties ---

    # 1. Your own hides of their messages
    own_hides = Message.where(nostr_author_pubkey: @pubkey)
                       .where.not(hidden_at: nil)
                       .count
    own_hide_penalty = [ own_hides * OWN_HIDE_WEIGHT, OWN_HIDE_CAP ].max

    # 2. Community report count (aggregated from NIP-56 and other sources)
    report_count = contact&.report_count || 0
    # Also check remote members for additional reports
    remote_reports = RemoteMember.where(pubkey: @pubkey).maximum(:report_count) || 0
    total_reports = [ report_count, remote_reports ].max
    report_penalty = [ total_reports * REPORT_WEIGHT, REPORT_CAP ].max

    # 3. Banned from servers the local user is in
    ban_count = if User.first # single-user instance
      server_ids = User.first.servers.pluck(:id)
      if server_ids.any?
        # Check bans by matching pubkey to banned users' nostr keys
        banned_user_ids = User.where(nostr_public_key: @pubkey).pluck(:id)
        if banned_user_ids.any?
          Ban.where(server_id: server_ids, user_id: banned_user_ids).count
        else
          0
        end
      else
        0
      end
    else
      0
    end
    ban_penalty = [ ban_count * BAN_WEIGHT, BAN_CAP ].max

    # Apply sensitivity multiplier to all penalties
    total_penalties = ((own_hide_penalty + report_penalty + ban_penalty) * @multiplier).round

    # --- Bonuses (not affected by sensitivity) ---
    bonuses = 0
    bonuses += FRIEND_BONUS if contact&.accepted?
    bonuses += KNOWN_BONUS if contact.present?

    {
      own_hides: own_hides,
      own_hide_penalty: own_hide_penalty,
      report_count: total_reports,
      report_penalty: report_penalty,
      ban_count: ban_count,
      ban_penalty: ban_penalty,
      is_friend: contact&.accepted? || false,
      is_known: contact.present?,
      penalties: total_penalties,
      bonuses: bonuses
    }
  end
end
