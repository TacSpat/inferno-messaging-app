class Nip05Cache < ApplicationRecord
  validates :identifier, presence: true, uniqueness: true
  validates :public_key, presence: true
  validates :verified_at, presence: true
  validates :expires_at, presence: true

  CACHE_TTL = 24.hours

  scope :valid, -> { where("expires_at > ?", Time.current) }

  def expired?
    expires_at < Time.current
  end

  # Look up a NIP-05 identifier, using cache or fetching fresh
  def self.lookup(identifier)
    cached = valid.find_by(identifier: identifier.downcase)
    return cached.public_key if cached

    # Parse identifier: "user@domain"
    name, domain = identifier.downcase.split("@", 2)
    return nil if name.blank? || domain.blank?

    # Fetch from remote instance
    public_key = fetch_from_remote(name, domain)
    return nil if public_key.blank?

    # Cache the result
    cache_entry = find_or_initialize_by(identifier: identifier.downcase)
    cache_entry.update!(
      public_key: public_key,
      verified_at: Time.current,
      expires_at: CACHE_TTL.from_now
    )

    public_key
  end

  def self.fetch_from_remote(name, domain)
    uri = URI::HTTPS.build(host: domain, path: "/.well-known/nostr.json", query: "name=#{CGI.escape(name)}")
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    data.dig("names", name)
  rescue StandardError => e
    Rails.logger.warn("NIP-05 lookup failed for #{name}@#{domain}: #{e.message}")
    nil
  end

  def self.cleanup_expired
    where("expires_at < ?", Time.current).delete_all
  end
end
