class RelayConnection < ApplicationRecord
  STATUSES = %w[active disabled error].freeze

  validates :url, presence: true, uniqueness: true
  validates :url, format: { with: /\Awss?:\/\/.+/i, message: "must be a WebSocket URL (wss:// or ws://)" }
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }
  scope :connectable, -> { active }

  def active?
    status == "active"
  end

  def disabled?
    status == "disabled"
  end

  def error?
    status == "error"
  end

  def mark_connected!
    update!(last_connected_at: Time.current, status: "active", last_error_message: nil)
  end

  def mark_error!(message)
    update!(
      last_error_at: Time.current,
      last_error_message: message,
      status: "error"
    )
  end

  def disable!
    update!(status: "disabled")
  end

  def enable!
    update!(status: "active", last_error_message: nil)
  end
end
