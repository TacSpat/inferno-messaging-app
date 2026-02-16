class User < ApplicationRecord
  include HasPublicId
  include HasNostrIdentity
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :confirmable

  # Remote user detail (for shadow users)
  belongs_to :remote_user_detail, class_name: "RemoteUser", optional: true

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

  # Friends
  has_many :friendships, dependent: :destroy
  has_many :accepted_friendships, -> { accepted }, class_name: "Friendship"
  has_many :friends, through: :accepted_friendships, source: :friend
  has_many :pending_friend_requests, -> { pending }, class_name: "Friendship", foreign_key: :friend_id
  has_many :sent_friend_requests, -> { pending }, class_name: "Friendship"

  # Blocks
  has_many :blocks, foreign_key: :blocker_id, dependent: :destroy
  has_many :blocked_users, through: :blocks, source: :blocked

  # Conversations
  has_many :conversation_participants, dependent: :destroy
  has_many :conversations, through: :conversation_participants

  # GIF collections & favorites
  has_many :gif_collections, dependent: :destroy
  has_many :gif_favorites, dependent: :destroy

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

  # Scopes
  scope :local, -> { where(remote: false) }
  scope :remote_users, -> { where(remote: true) }

  # Online state
  enum :online_state, { offline: 0, online: 1, idle: 2, dnd: 3, invisible: 4 }

  # Callbacks
  before_validation :assign_discriminator, on: :create
  before_validation :default_display_name, on: :create
  after_update_commit :broadcast_profile_update, if: :profile_changed?
  after_update_commit :publish_nostr_profile, if: :nostr_profile_changed?

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

  def friends_with?(user)
    friendships.accepted.exists?(friend_id: user.id)
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
      folder_servers = memberships.select { |m| m.server_folder_id == folder.id }.map(&:server)
      items << { type: :folder, folder: folder, servers: folder_servers, position: folder.position }
    end

    # Add top-level servers (not in any folder)
    memberships.select { |m| m.server_folder_id.nil? }.each do |m|
      items << { type: :server, server: m.server, position: m.position }
    end

    items.sort_by { |item| item[:position] }
  end

  private

  def profile_changed?
    saved_change_to_username? || saved_change_to_display_name? || saved_change_to_bio? || saved_change_to_status? || saved_change_to_status_emoji?
  end

  def nostr_profile_changed?
    !remote? && nostr_public_key.present? && (saved_change_to_username? || saved_change_to_display_name? || saved_change_to_bio?)
  end

  def publish_nostr_profile
    NostrPublishJob.perform_later(id, :profile)
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

  def assign_discriminator
    return if discriminator.present? && discriminator != "0000"
    taken = User.where(username: username).pluck(:discriminator)
    available = ("0001".."9999").to_a - taken
    self.discriminator = available.sample || "0000"
  end

  def default_display_name
    self.display_name = username if display_name.blank?
  end
end
