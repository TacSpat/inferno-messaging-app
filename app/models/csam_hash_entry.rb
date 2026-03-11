class CsamHashEntry < ApplicationRecord
  validates :hash_value, presence: true
  validates :hash_type, presence: true

  # Check if a hash matches any CSAM entry (exact match)
  def self.match?(hash_value, hash_type: "dhash")
    where(hash_value: hash_value, hash_type: hash_type).exists?
  end

  # Fuzzy match using hamming distance (reuses ContentHash logic)
  def self.fuzzy_match?(hash_value, hash_type: "dhash", threshold: 10)
    # Exact match first (fast)
    return true if match?(hash_value, hash_type: hash_type)

    # Fuzzy match against all entries of this type
    where(hash_type: hash_type).find_each do |entry|
      distance = ContentHash.hamming_distance(entry.hash_value, hash_value)
      return true if distance <= threshold
    end
    false
  end

  # Promote a shared ContentHash to the permanent CSAM table
  # Called when a shared hash reaches high confidence with severe report reasons
  def self.promote_from_shared!(content_hash)
    find_or_create_by!(
      hash_value: content_hash.hash_value,
      hash_type: content_hash.hash_type
    ) do |entry|
      entry.list_source = "shared_network"
      entry.added_at = Time.current
    end
  end
end
