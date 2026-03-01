# Full Nostr event storage for the embedded relay.
# Events are stored verbatim and served to clients.
class NostrEvent < ApplicationRecord
  validates :event_id, presence: true, uniqueness: true
  validates :kind, presence: true
  validates :pubkey, presence: true
  validates :sig, presence: true
  validates :event_created_at, presence: true

  scope :by_kind, ->(kind) { where(kind: kind) }
  scope :by_author, ->(pubkey) { where(pubkey: pubkey) }
  scope :by_authors, ->(pubkeys) { where(pubkey: pubkeys) }
  scope :since, ->(timestamp) { where("event_created_at >= ?", Time.at(timestamp)) }
  scope :until_time, ->(timestamp) { where("event_created_at <= ?", Time.at(timestamp)) }

  # Build the NIP-01 event JSON for relay responses
  def to_nostr_event
    {
      "id" => event_id,
      "pubkey" => pubkey,
      "created_at" => event_created_at.to_i,
      "kind" => kind,
      "tags" => tags || [],
      "content" => content || "",
      "sig" => sig
    }
  end

  # Store an event from raw NIP-01 format
  def self.store_event(event_hash)
    create!(
      event_id: event_hash["id"],
      kind: event_hash["kind"],
      pubkey: event_hash["pubkey"],
      content: event_hash["content"],
      tags: event_hash["tags"],
      sig: event_hash["sig"],
      event_created_at: Time.at(event_hash["created_at"].to_i)
    )
  rescue ActiveRecord::RecordNotUnique
    # Already stored
    find_by(event_id: event_hash["id"])
  end

  # Apply a NIP-01 filter to query events
  def self.apply_filter(filter)
    scope = all

    scope = scope.by_kind(filter["kinds"]) if filter["kinds"].present?
    scope = scope.by_authors(filter["authors"]) if filter["authors"].present?
    scope = scope.where("event_id IN (?)", filter["ids"]) if filter["ids"].present?
    scope = scope.since(filter["since"]) if filter["since"].present?
    scope = scope.until_time(filter["until"]) if filter["until"].present?

    # Tag filters (#e, #p, #h, etc.)
    filter.each do |key, values|
      next unless key.start_with?("#") && key.length == 2
      tag_name = key[1]
      next unless values.is_a?(Array) && values.any?

      # SQLite JSON search for tag values
      values.each do |val|
        scope = scope.where("EXISTS (SELECT 1 FROM json_each(tags) AS t WHERE json_extract(t.value, '$[0]') = ? AND json_extract(t.value, '$[1]') = ?)", tag_name, val)
      end
    end

    limit = [ filter["limit"] || 500, 1000 ].min
    scope.order(event_created_at: :desc).limit(limit)
  end
end
