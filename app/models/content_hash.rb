class ContentHash < ApplicationRecord
  belongs_to :message, optional: true

  validates :hash_value, presence: true
  validates :hash_type, presence: true

  scope :blockable, -> {
    where(allowlisted: false)
      .where("source = 'local' OR confidence >= ?",
             LocalConfig.current.safety_shared_hash_min_reporters)
  }

  scope :local_hashes, -> { where(source: "local") }
  scope :shared_hashes, -> { where(source: "shared") }
  scope :allowlisted_hashes, -> { where(allowlisted: true) }

  # Compare two hashes using hamming distance.
  # Lower = more similar. 0 = identical.
  def self.hamming_distance(hash_a, hash_b)
    return Float::INFINITY if hash_a.nil? || hash_b.nil?
    a = hash_a.to_i(16)
    b = hash_b.to_i(16)
    (a ^ b).to_s(2).count("1")
  end

  # Find stored hashes that are perceptually similar to the given hash.
  # threshold: max hamming distance (default 10 out of 64 bits ~ 84% similar)
  def self.find_similar(hash_value, hash_type: "dhash", threshold: 10)
    # Two-tier: exact match first (fast), then fuzzy on blockable scope
    exact = blockable.where(hash_type: hash_type, hash_value: hash_value)
    return exact if exact.any?

    blockable.where(hash_type: hash_type).select do |ch|
      hamming_distance(ch.hash_value, hash_value) <= threshold
    end
  end

  # Check if a hash matches any stored hash (boolean shortcut)
  def self.match?(hash_value, hash_type: "dhash", threshold: 10)
    find_similar(hash_value, hash_type: hash_type, threshold: threshold).any?
  end

  # Allowlist this hash and any shared hashes within hamming distance
  def allowlist!
    # Never allowlist hashes that match the CSAM database
    return false if CsamHashEntry.match?(hash_value, hash_type: hash_type)

    update!(allowlisted: true)

    # Also allowlist similar shared hashes
    ContentHash.shared_hashes.where(hash_type: hash_type).find_each do |ch|
      next if ch.allowlisted?
      if ContentHash.hamming_distance(hash_value, ch.hash_value) <= 10
        ch.update!(allowlisted: true)
      end
    end
  end

  # Recompute confidence based on reporter weights
  def compute_confidence(trust_friends: true)
    pubkeys = reporter_pubkeys || []
    self.confidence = pubkeys.sum do |pubkey|
      if trust_friends
        contact = Contact.find_by(pubkey: pubkey)
        if contact&.accepted?
          1.0
        elsif contact
          0.3
        else
          0.1
        end
      else
        1.0 / 3.0 # Equal weight when trust is disabled
      end
    end
    save! if persisted?

    # Auto-promote to CSAM table when confidence is very high
    maybe_promote_to_csam! if confidence >= 5.0

    confidence
  end

  private

  # When a shared hash reaches high confidence from trusted reporters,
  # promote it to the permanent CSAM hash table (non-overridable).
  # Threshold: confidence >= 5.0 with at least 2 friend reporters or 15+ strangers.
  def maybe_promote_to_csam!
    return unless source == "shared"
    return if allowlisted?
    return if CsamHashEntry.exists?(hash_value: hash_value, hash_type: hash_type)

    friend_count = (reporter_pubkeys || []).count do |pk|
      Contact.find_by(pubkey: pk)&.accepted?
    end

    promote = friend_count >= 2 || (reporter_pubkeys || []).size >= 15
    return unless promote

    CsamHashEntry.create!(
      hash_value: hash_value,
      hash_type: hash_type,
      list_source: "shared_network",
      added_at: Time.current
    )
    Rails.logger.info("[ContentHash] Promoted shared hash #{hash_value[0..15]}... to CSAM table (confidence: #{confidence})")
  end
end
