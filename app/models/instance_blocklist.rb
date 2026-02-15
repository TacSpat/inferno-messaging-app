class InstanceBlocklist < ApplicationRecord
  belongs_to :blocked_by, class_name: "User"

  validates :domain, presence: true, uniqueness: { case_sensitive: false }
  validates :domain, format: { with: /\A[a-z0-9]+([\-.][a-z0-9]+)*\.[a-z]{2,}\z/i, message: "must be a valid domain" }

  before_validation :normalize_domain

  scope :ordered, -> { order(blocked_at: :desc) }

  def self.blocked?(domain)
    where("LOWER(domain) = ?", domain.downcase).exists?
  end

  private

  def normalize_domain
    self.domain = domain&.downcase&.strip
  end
end
