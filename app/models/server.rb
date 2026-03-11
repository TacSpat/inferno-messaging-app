class Server < ApplicationRecord
  include HasPublicId
  belongs_to :owner, class_name: "User"
  belongs_to :welcome_channel, class_name: "Channel", optional: true
  belongs_to :afk_channel, class_name: "Channel", optional: true
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
  has_many :voice_states, dependent: :destroy
  has_many :server_voice_providers, dependent: :destroy
  has_many :nostr_event_logs, dependent: :destroy
  has_many :notifications, dependent: :destroy
  has_many :voice_showcases, dependent: :destroy
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

  def prunable_memberships(days:)
    cutoff = days.days.ago
    server_memberships
      .joins(:user)
      .where("users.online_at < ? OR users.online_at IS NULL", cutoff)
      .where.not(user: owner)
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

  SERVER_TYPES = %w[community friends_family gaming work_team adult].freeze

  CHANNEL_TEMPLATES = {
    "community" => [
      { category: "Information", channels: [
        { name: "welcome", type: :text, read_only: true },
        { name: "rules", type: :text, read_only: true }
      ]},
      { category: "Text Channels", channels: [
        { name: "general", type: :text },
        { name: "off-topic", type: :text },
        { name: "media", type: :text }
      ]},
      { category: "Announcements", channels: [
        { name: "announcements", type: :text, mod_only: true }
      ]}
    ],
    "friends_family" => [
      { category: "Text Channels", channels: [
        { name: "general", type: :text },
        { name: "photos", type: :text }
      ]},
      { category: "Voice", channels: [
        { name: "hangout", type: :voice }
      ]}
    ],
    "gaming" => [
      { category: "Text Channels", channels: [
        { name: "general", type: :text },
        { name: "lfg", type: :text },
        { name: "screenshots", type: :text },
        { name: "clips", type: :text }
      ]},
      { category: "Voice", channels: [
        { name: "lobby-1", type: :voice },
        { name: "lobby-2", type: :voice }
      ]}
    ],
    "work_team" => [
      { category: "General", channels: [
        { name: "general", type: :text },
        { name: "random", type: :text }
      ]},
      { category: "Work", channels: [
        { name: "announcements", type: :text, mod_only: true },
        { name: "standup", type: :text },
        { name: "projects", type: :text }
      ]}
    ],
    "adult" => [
      { category: "Verification", channels: [
        { name: "rules", type: :text, read_only: true },
        { name: "verification-submit", type: :text, post_only: true }
      ]},
      { category: "Text Channels", channels: [
        { name: "general", type: :text },
        { name: "media", type: :text }
      ]},
      { category: "Voice", channels: [
        { name: "voice", type: :voice }
      ]}
    ]
  }.freeze

  # Apply a server type template after creation.
  # Creates channels, categories, and additional roles based on the type.
  def apply_server_template!(type)
    return unless SERVER_TYPES.include?(type)

    update_column(:server_type, type)

    template = CHANNEL_TEMPLATES[type]
    return unless template

    # Remove the default general channel and text category created by create_defaults
    channels.destroy_all
    categories.destroy_all

    everyone_role = roles.find_by(name: "@everyone")

    # Create mod role for types that need it
    if type.in?(%w[community gaming adult])
      roles.find_or_create_by!(name: "Mod") do |r|
        r.position = 5
        r.color = "#ffffff"
        r.permissions = Role::MOD_PERMISSIONS
      end
    end

    # Create Manager role for work/team
    if type == "work_team"
      roles.find_or_create_by!(name: "Manager") do |r|
        r.position = 5
        r.color = "#ffffff"
        r.permissions = Role::MOD_PERMISSIONS
      end
    end

    # Create Verified role for age-restricted servers
    if type == "adult"
      update_column(:age_restricted, true)
      roles.find_or_create_by!(name: "Verified") do |r|
        r.position = 2
        r.color = "#ffffff"
        r.permissions = Role::DEFAULT_PERMISSIONS
      end
    end

    first_channel = nil

    template.each_with_index do |cat_config, cat_idx|
      category = categories.create!(name: cat_config[:category], position: cat_idx)

      cat_config[:channels].each_with_index do |ch_config, ch_idx|
        channel = channels.create!(
          name: ch_config[:name],
          channel_type: ch_config[:type],
          position: ch_idx,
          category: category,
          post_only: ch_config[:post_only] || false
        )

        first_channel ||= channel if channel.text?
      end
    end

    update_column(:welcome_channel_id, first_channel&.id)

    # Re-create the invite since channels were destroyed
    invites.destroy_all
    invites.create!(creator: owner)
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
