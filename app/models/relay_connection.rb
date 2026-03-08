class RelayConnection < ApplicationRecord
  STATUSES = %w[active disabled error].freeze

  validates :url, presence: true, uniqueness: true
  validates :url, format: { with: /\Awss?:\/\/.+/i, message: "must be a WebSocket URL (wss:// or ws://)" }
  validates :status, inclusion: { in: STATUSES }

  def self.find_or_create_for_relay(relay_url)
    relay_url = relay_url.to_s.strip
    return nil if relay_url.blank? || !relay_url.match?(/\Awss?:\/\/.+/i)
    find_or_create_by(url: relay_url) do |conn|
      conn.status = "active"
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    find_by(url: relay_url)
  end

  scope :active, -> { where(status: "active") }
  scope :connectable, -> { active }
  scope :externally_reachable, -> {
    active.where.not("url LIKE 'ws://localhost%'")
          .where.not("url LIKE 'ws://127.%'")
          .where.not("url LIKE 'ws://10.%'")
          .where.not("url LIKE 'ws://192.168.%'")
  }
  scope :healthy, -> { active.where("last_error_at IS NULL OR last_error_at < ?", 1.hour.ago) }

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
    update!(last_connected_at: Time.current, status: "active", last_error_message: nil, retry_count: 0)
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
