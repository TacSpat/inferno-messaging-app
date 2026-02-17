class FederationAuditLog < ApplicationRecord
  EVENT_TYPES = %w[
    auth_attempt
    auth_success
    auth_failure
    token_issued
    domain_block
    domain_unblock
    lockdown_activated
    lockdown_lifted
    moderation_report_reviewed
    user_suspended
    user_suspension_lifted
  ].freeze

  belongs_to :actor, polymorphic: true, optional: true
  belongs_to :target, polymorphic: true, optional: true

  validates :event_type, presence: true, inclusion: { in: EVENT_TYPES }

  scope :by_event, ->(type) { where(event_type: type) }
  scope :by_domain, ->(domain) { where(remote_domain: domain) }
  scope :recent, ->(limit = 50) { order(created_at: :desc).limit(limit) }
  scope :in_range, ->(from, to) { where(created_at: from..to) }

  def readonly?
    persisted?
  end
end
