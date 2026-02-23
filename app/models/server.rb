class Server < ApplicationRecord
  include HasPublicId
  belongs_to :owner, class_name: "User"
  belongs_to :welcome_channel, class_name: "Channel", optional: true
  has_many :channels, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :server_memberships, dependent: :destroy
  has_many :members, through: :server_memberships, source: :user
  has_many :roles, dependent: :destroy
  has_many :invites, dependent: :destroy
  has_many :bans, dependent: :destroy
  has_many :server_emojis, dependent: :destroy
  has_many :server_stickers, dependent: :destroy
  has_many :remote_members, dependent: :destroy
  has_many :server_voice_providers, dependent: :destroy
  has_one_attached :icon
  has_one_attached :banner

  validates :name, presence: true, length: { maximum: 100 }

  after_create :create_defaults
  after_create :assign_nostr_group_id

  # All members: local users + remote members (excluding remotes whose pubkey matches a local user)
  def all_members
    local = members.includes(server_memberships: :roles, avatar_attachment: :blob)
    local_pubkeys = local.filter_map(&:nostr_public_key)
    remote = remote_members.includes(:roles)
    remote = remote.where.not(pubkey: local_pubkeys) if local_pubkeys.any?
    local.to_a + remote.to_a
  end

  def total_member_count
    members.count + remote_members.where.not(pubkey: User.where.not(nostr_public_key: nil).select(:nostr_public_key)).count
  end

  # Effective relay URLs: server-specific + global relays
  def effective_relay_urls
    urls = (relay_urls || [])
    global = RelayConnection.active.pluck(:url)
    (urls + global).uniq
  end

  def send_welcome_message(user)
    return unless welcome_message_enabled?
    channel = welcome_channel || channels.ordered.first
    return unless channel

    content = (welcome_message_template.presence || "Welcome to the server, {user}! \xF0\x9F\x8E\x89")
      .gsub("{user}", "**#{user.display_name.presence || user.username}**")
      .gsub("{server}", name)
      .gsub("{tag}", user.tag)

    message = channel.messages.create!(
      content: content,
      user: user,
      system_message: true
    )

    ChannelChatChannel.broadcast_to(
      channel,
      {
        type: "new_message",
        html: ApplicationController.render(
          partial: "messages/message",
          locals: { message: message, server: self }
        )
      }
    )
  end

  def voice_ready?
    voice_enabled? && server_voice_providers.active.any?
  end

  # Pick the active provider with fewest current channel assignments (load balance).
  # Returns the ServerVoiceProvider record (not the User).
  # exclude_ids: provider user IDs to skip (e.g., a failed provider during failover).
  def pick_voice_provider(exclude_ids: [])
    providers = server_voice_providers.active.includes(:user)
    providers = providers.where.not(user_id: exclude_ids) if exclude_ids.any?
    return nil if providers.empty?

    # Count how many channels each provider is currently serving
    # Remote providers (no user_id) get load 0 since they don't track local channels
    provider_load = providers.each_with_object({}) do |svp, hash|
      hash[svp] = svp.user_id ? Channel.where(current_voice_provider_id: svp.user_id).count : 0
    end

    provider_load.min_by { |_svp, count| count }.first
  end

  private

  def assign_nostr_group_id
    update_column(:nostr_group_id, "inferno-#{public_id}") if nostr_group_id.blank?
  end

  def create_defaults
    everyone_role = roles.create!(name: "@everyone", position: 0, color: "#ffffff", permissions: Role::DEFAULT_PERMISSIONS)
    admin_role = roles.create!(name: "Admin", position: 10, color: "#ffffff", permissions: Role::ADMIN_PERMISSIONS)
    owner_role = roles.create!(name: "Owner", position: 100, color: "#ffffff", permissions: Role::OWNER_PERMISSIONS)

    text_category = categories.create!(name: "Text Channels", position: 0)
    general = channels.create!(name: "general", channel_type: :text, position: 0, category: text_category)

    update_column(:welcome_channel_id, general.id)

    membership = server_memberships.create!(user: owner, joined_at: Time.current)
    membership.roles << owner_role
    invites.create!(creator: owner)
  end
end
