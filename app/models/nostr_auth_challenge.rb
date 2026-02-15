class NostrAuthChallenge < ApplicationRecord
  validates :nonce, presence: true, uniqueness: true
  validates :requesting_domain, presence: true
  validates :callback_url, presence: true
  validates :expires_at, presence: true

  scope :valid_for_nonce, ->(nonce) {
    where(nonce: nonce, used: false)
      .where("expires_at > ?", Time.current)
  }

  def expired?
    expires_at < Time.current
  end

  def consume!
    update!(used: true)
  end

  # Clean up old challenges periodically
  def self.cleanup_expired
    where("expires_at < ? OR used = ?", 1.hour.ago, true).delete_all
  end
end
