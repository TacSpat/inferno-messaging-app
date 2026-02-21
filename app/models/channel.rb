class Channel < ApplicationRecord
  include HasPublicId
  include InstanceLimits
  belongs_to :server
  belongs_to :category, optional: true
  has_many :messages, dependent: :destroy
  has_many :channel_reads, dependent: :destroy
  has_many :nostr_event_logs, dependent: :destroy

  def unread_for?(user)
    last_message_at = messages.maximum(:created_at)
    return false unless last_message_at
    read = channel_reads.find_by(user: user)
    return true unless read
    read.last_read_at < last_message_at
  end

  enum :channel_type, { text: 0, announcement: 2 }

  validates :name, presence: true, length: { maximum: 100 },
            format: { with: /\A[a-z0-9 _\-:\u{00A0}-\u{10FFFF}]+\z/, message: "lowercase letters, numbers, spaces, hyphens, underscores, and emojis only" }
  validates :channel_type, presence: true
  validate :within_channel_limit, on: :create

  scope :ordered, -> { order(position: :asc, created_at: :asc) }
  scope :uncategorized, -> { where(category_id: nil) }

  # All channels are Nostr-backed
  after_create :assign_nostr_group_id

  # Enable sharing on specific relays
  def enable_sharing!(relay_url:, group_id: nil)
    urls = (nostr_relay_urls || []) | [relay_url]
    update!(
      shared: true,
      nostr_relay_url: relay_url,
      nostr_relay_urls: urls,
      nostr_group_id: group_id || generate_group_id
    )
  end

  # Bridge to an existing external NIP-29 group
  def bridge_to!(relay_url:, group_id:)
    urls = (nostr_relay_urls || []) | [relay_url]
    update!(
      shared: true,
      nostr_relay_url: relay_url,
      nostr_relay_urls: urls,
      nostr_group_id: group_id
    )
  end

  # Disable sharing
  def unbridge!
    update!(
      shared: false,
      nostr_group_id: nil,
      nostr_relay_url: nil,
      nostr_relay_urls: nil
    )
  end

  # All relay URLs this channel publishes to
  def effective_relay_urls
    urls = nostr_relay_urls || []
    urls << nostr_relay_url if nostr_relay_url.present? && !urls.include?(nostr_relay_url)
    # Include globally configured relays
    RelayConnection.active.pluck(:url).each do |url|
      urls << url unless urls.include?(url)
    end
    urls
  end

  private

  def generate_group_id
    "#{server.public_id}-#{public_id}"
  end

  def assign_nostr_group_id
    update_column(:nostr_group_id, generate_group_id) if nostr_group_id.blank?
  end

  def within_channel_limit
    if server && instance_config.channel_limit_reached_for?(server)
      errors.add(:base, "This server has reached its channel limit (#{instance_config.max_channels_per_server})")
    end
  end
end
