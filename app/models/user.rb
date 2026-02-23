class User < ApplicationRecord
  include HasPublicId
  include HasNostrIdentity
  devise :database_authenticatable, :rememberable

  # Profile
  has_one_attached :avatar
  has_one_attached :banner

  # Servers
  has_many :server_memberships, dependent: :destroy
  has_many :servers, -> { order("server_memberships.position ASC, server_memberships.joined_at ASC") }, through: :server_memberships
  has_many :owned_servers, class_name: "Server", foreign_key: :owner_id, dependent: :nullify
  has_many :server_folders, dependent: :destroy

  # Invites
  has_many :created_invites, class_name: "Invite", foreign_key: :creator_id, dependent: :destroy

  # Messages
  has_many :messages, dependent: :nullify

  # Contacts (replaces Friendship model — all friends are external Nostr contacts)
  def contacts
    Contact.all
  end

  def friend_contacts
    Contact.friends
  end

  def pending_incoming_contacts
    Contact.pending_incoming
  end

  def pending_outgoing_contacts
    Contact.pending_outgoing
  end

  def pending_contact_count
    Contact.pending_incoming.count
  end

  # Blocks
  has_many :blocks, foreign_key: :blocker_id, dependent: :destroy
  has_many :blocked_users, through: :blocks, source: :blocked

  # Conversations
  has_many :conversation_participants, dependent: :destroy
  has_many :conversations, through: :conversation_participants

  # GIF collections & favorites
  has_many :gif_collections, dependent: :destroy
  has_many :gif_favorites, dependent: :destroy

  # Voice providers
  has_many :server_voice_providers, dependent: :destroy

  # Themes
  THEMES = %w[inferno frostfire boron brimstone plasma pulsar obsidian].freeze

  # Notifications
  has_many :notifications, dependent: :destroy

  # Channel reads
  has_many :channel_reads, dependent: :destroy

  # Validations
  validates :username, presence: true, length: { minimum: 2, maximum: 32 }
  validates :discriminator, presence: true,
            format: { with: /\A\d{4}\z/, message: "must be 4 digits" }
  validates :discriminator, uniqueness: { scope: :username, message: "is taken for this username" }
  validates :display_name, length: { maximum: 32 }, allow_blank: true
  validates :bio, length: { maximum: 500 }, allow_blank: true
  validates :status, length: { maximum: 128 }, allow_blank: true
  validates :theme, inclusion: { in: THEMES }

  # Online state
  enum :online_state, { offline: 0, online: 1, idle: 2, dnd: 3, invisible: 4 }

  # Callbacks
  before_validation :assign_discriminator, on: :create
  before_validation :default_display_name, on: :create
  after_update_commit :broadcast_profile_update, if: :profile_changed?
  after_update_commit :publish_nostr_profile, if: :nostr_profile_changed?

  # The single owner of this local instance
  def self.owner
    first
  end

  # Full tag like "Tac#0420"
  def tag
    "#{username}##{discriminator}"
  end

  # Display name cascade: server nickname > display_name > username
  def display_name_for(server = nil)
    if server
      membership = if server_memberships.loaded?
        server_memberships.find { |sm| sm.server_id == server.id }
      else
        server_memberships.find_by(server: server)
      end
      return membership.nickname if membership&.nickname.present?
    end
    display_name.presence || username
  end

  def blocked?(user)
    blocks.exists?(blocked_id: user.id)
  end

  # Returns Blossom URL if uploaded, otherwise falls back to Active Storage path
  def effective_avatar_url
    return nil unless avatar.attached?
    avatar.blob.metadata&.dig("blossom_url") ||
      Rails.application.routes.url_helpers.rails_blob_path(avatar, only_path: true)
  end

  def effective_banner_url
    return nil unless banner.attached?
    banner.blob.metadata&.dig("blossom_url") ||
      Rails.application.routes.url_helpers.rails_blob_path(banner, only_path: true)
  end

  def remote?
    false
  end

  # LiveKit encrypted secret management
  def livekit_api_secret
    return nil if livekit_api_secret_enc.blank?
    livekit_encryptor.decrypt_and_verify(livekit_api_secret_enc)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end

  def livekit_api_secret=(value)
    if value.present?
      self.livekit_api_secret_enc = livekit_encryptor.encrypt_and_sign(value)
    else
      self.livekit_api_secret_enc = nil
    end
  end

  def livekit_configured?
    livekit_url.present? && livekit_api_key.present? && livekit_api_secret_enc.present?
  end

  def friends_with_pubkey?(pubkey)
    Contact.friends.exists?(pubkey: pubkey)
  end

  def friends_with?(other_user)
    return false unless other_user&.nostr_public_key.present?
    friends_with_pubkey?(other_user.nostr_public_key)
  end

  def role_color_for(server)
    return "#ffffff" unless server
    membership = if server_memberships.loaded?
      server_memberships.find { |sm| sm.server_id == server.id }
    else
      server_memberships.find_by(server: server)
    end
    return "#ffffff" unless membership
    membership.top_role&.color || "#ffffff"
  end

  def ordered_rail_items
    memberships = server_memberships.includes(:server, :server_folder).ordered
    folders = server_folders.ordered.includes(server_memberships: :server)

    items = []

    # Add folders with their servers
    folders.each do |folder|
      folder_items = []
      memberships.select { |m| m.server_folder_id == folder.id }.each do |m|
        folder_items << { type: :server, server: m.server, position: m.position }
      end
      folder_items.sort_by! { |i| i[:position] }
      items << { type: :folder, folder: folder, items: folder_items, position: folder.position }
    end

    # Add top-level servers (not in any folder)
    memberships.select { |m| m.server_folder_id.nil? }.each do |m|
      items << { type: :server, server: m.server, position: m.position }
    end

    items.sort_by { |item| item[:position] }
  end

  def broadcast_profile_update
    servers.each do |server|
      html = ApplicationController.render(
        partial: "servers/member_item",
        locals: { member: self, server: server }
      )
      ServerChannel.broadcast_to(server, {
        type: "member_update",
        user_id: public_id,
        html: html,
        display_name: display_name_for(server),
        username: username,
        tag: tag,
        role_color: role_color_for(server)
      })
    end
  end

  def publish_member_events
    return unless nostr_public_key.present?
    servers.each do |server|
      next unless server.nostr_group_id.present?
      NostrServerPublishJob.perform_later(id, server.id, "member", pubkey: nostr_public_key)
    end
  end

  private

  def profile_changed?
    saved_change_to_username? || saved_change_to_display_name? || saved_change_to_bio? ||
      saved_change_to_status? || saved_change_to_status_emoji? ||
      saved_change_to_profile_color? || saved_change_to_profile_color_2? ||
      saved_change_to_banner_offset_y? || saved_change_to_discriminator?
  end

  def nostr_profile_changed?
    nostr_public_key.present? && (
      saved_change_to_username? || saved_change_to_display_name? || saved_change_to_bio? ||
      saved_change_to_status? || saved_change_to_status_emoji? ||
      saved_change_to_profile_color? || saved_change_to_profile_color_2?
    )
  end

  def publish_nostr_profile
    NostrPublishJob.perform_later(id, :profile)
    # Also re-publish member events so remote instances get updated profile data
    publish_member_events
  end

  def assign_discriminator
    return if discriminator.present? && discriminator != "0000"
    taken = User.where(username: username).pluck(:discriminator)
    available = ("0001".."9999").to_a - taken
    self.discriminator = available.sample || "0000"
  end

  def default_display_name
    self.display_name = username if display_name.blank?
  end

  def livekit_encryptor
    key = ActiveSupport::KeyGenerator.new(
      Rails.application.secret_key_base
    ).generate_key("livekit secret encryption", 32)
    ActiveSupport::MessageEncryptor.new(key)
  end
end
