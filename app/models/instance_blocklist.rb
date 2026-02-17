class InstanceBlocklist < ApplicationRecord
  has_paper_trail
  has_one :domain_block_snapshot, dependent: :destroy

  belongs_to :blocked_by, class_name: "User"

  validates :domain, presence: true, uniqueness: { case_sensitive: false }
  validates :domain, format: { with: /\A[a-z0-9]+([\-.][a-z0-9]+)*\.[a-z]{2,}\z/i, message: "must be a valid domain" }

  before_validation :normalize_domain
  after_create :create_domain_snapshot

  scope :ordered, -> { order(blocked_at: :desc) }

  def self.blocked?(domain)
    where("LOWER(domain) = ?", domain.downcase).exists?
  end

  private

  def normalize_domain
    self.domain = domain&.downcase&.strip
  end

  def create_domain_snapshot
    DomainBlockSnapshotService.call(self)
  rescue StandardError => e
    Rails.logger.error("[InstanceBlocklist] Failed to create domain snapshot: #{e.message}")
  end
end
