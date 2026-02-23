class Channel < ApplicationRecord
  include HasPublicId
  include InstanceLimits
  belongs_to :server
  belongs_to :category, optional: true
  has_many :messages, dependent: :destroy
  has_many :channel_reads, dependent: :destroy
  has_many :nostr_event_logs, dependent: :destroy
  has_many :voice_states, dependent: :destroy
  belongs_to :current_voice_provider, class_name: "User", optional: true

  def unread_for?(user)
    last_message_at = messages.maximum(:created_at)
    return false unless last_message_at
    read = channel_reads.find_by(user: user)
    return true unless read
    read.last_read_at < last_message_at
  end

  enum :channel_type, { text: 0, voice: 1, announcement: 2 }

  before_validation { self.name = name.downcase if name.present? }

  validates :name, presence: true, length: { maximum: 100 },
            format: { with: /\A[a-z0-9 _\-:\u{00A0}-\u{10FFFF}]+\z/, message: "lowercase letters, numbers, spaces, hyphens, underscores, and emojis only" }
  validates :channel_type, presence: true
  validate :within_channel_limit, on: :create

  scope :ordered, -> { order(position: :asc, created_at: :asc) }
  scope :uncategorized, -> { where(category_id: nil) }

  # All channels are Nostr-backed
  after_create :assign_nostr_group_id
  after_create :generate_channel_keypair!, if: :encrypted?
  after_save :generate_channel_keypair_on_encrypt!, if: -> { saved_change_to_encrypted? && encrypted? && channel_public_key.blank? }
  after_save :purge_encrypted_history!, if: -> { saved_change_to_encrypted? && !encrypted? }

  # Keypair management for encrypted channels (mirrors HasNostrIdentity)
  def generate_channel_keypair!
    private_key = Nostr::Key.generate_private_key
    public_key = Nostr::Key.get_public_key(private_key)

    update_columns(
      channel_public_key: public_key,
      encrypted_channel_private_key: channel_encryptor.encrypt_and_sign(private_key)
    )
  end

  def channel_private_key
    return nil if encrypted_channel_private_key.blank?
    channel_encryptor.decrypt_and_verify(encrypted_channel_private_key)
  end

  # Returns :full, :read_only, or false
  def visible_to?(user)
    return :full unless encrypted?

    membership = user.server_memberships.find_by(server: server)
    return :full if membership&.owner? || membership&.admin?

    allowed_ids = permissions_overrides&.dig("allowed_role_ids")
    if allowed_ids.present? && membership
      user_role_ids = membership.roles.pluck(:public_id)
      return :full if (allowed_ids & user_role_ids).any?
    end

    # No access — check if user has any association with this channel
    # channel_reads means the user visited this channel at some point
    has_history = channel_reads.where(user: user).exists?
    has_history ? :read_only : false
  end

  scope :accessible_to, ->(user) {
    # Non-encrypted channels are always accessible
    non_encrypted = where(encrypted: [false, nil])

    # For encrypted channels, we need to check visibility
    encrypted_ids = where(encrypted: true).select { |ch| ch.visible_to?(user) }.map(&:id)

    where(id: non_encrypted.select(:id)).or(where(id: encrypted_ids))
  }

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

  def generate_channel_keypair_on_encrypt!
    generate_channel_keypair!
  end

  # When encryption is removed, purge all messages from the encrypted era.
  # They were only meant for users who had access at the time — letting
  # them surface to new/unauthorized members would leak private content.
  # The keypair is also destroyed so old relay ciphertext becomes unrecoverable.
  def purge_encrypted_history!
    messages.destroy_all
    channel_reads.delete_all
    nostr_event_logs.delete_all
    update_columns(
      channel_public_key: nil,
      encrypted_channel_private_key: nil
    )
  end

  def channel_encryptor
    key = ActiveSupport::KeyGenerator.new(
      Rails.application.secret_key_base
    ).generate_key("channel keypair encryption", 32)
    ActiveSupport::MessageEncryptor.new(key)
  end

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
