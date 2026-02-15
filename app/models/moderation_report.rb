class ModerationReport < ApplicationRecord
  REPORT_TYPES = %w[spam illegal impersonation harassment other].freeze
  STATUSES = %w[open reviewed dismissed actioned].freeze

  belongs_to :reporter, class_name: "User"
  belongs_to :reviewed_by, class_name: "User", optional: true

  validates :reported_pubkey, presence: true
  validates :report_type, presence: true, inclusion: { in: REPORT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :open_reports, -> { where(status: "open") }
  scope :resolved, -> { where(status: %w[reviewed dismissed actioned]) }
  scope :by_pubkey, ->(pubkey) { where(reported_pubkey: pubkey) }

  def open?
    status == "open"
  end

  def resolved?
    %w[reviewed dismissed actioned].include?(status)
  end

  def review!(admin, new_status:)
    update!(status: new_status, reviewed_by: admin)
  end

  # Find the remote user record, if any
  def reported_remote_user
    RemoteUser.find_by(nostr_public_key: reported_pubkey)
  end

  # Find the local user by pubkey, if any
  def reported_user
    User.find_by(nostr_public_key: reported_pubkey)
  end
end
