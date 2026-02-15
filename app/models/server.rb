class Server < ApplicationRecord
  include HasPublicId
  belongs_to :owner, class_name: "User"
  belongs_to :welcome_channel, class_name: "Channel", optional: true
  has_paper_trail
  has_many :channels, dependent: :destroy
  has_many :categories, dependent: :destroy
  has_many :server_memberships, dependent: :destroy
  has_many :members, through: :server_memberships, source: :user
  has_many :roles, dependent: :destroy
  has_many :invites, dependent: :destroy
  has_many :bans, dependent: :destroy
  has_one_attached :icon

  validates :name, presence: true, length: { maximum: 100 }

  after_create :create_defaults

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

    # Broadcast so it appears in real-time
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

  private

  def create_defaults
    everyone_role = roles.create!(name: "@everyone", position: 0, color: "#ffffff", permissions: Role::DEFAULT_PERMISSIONS)
    admin_role = roles.create!(name: "Admin", position: 10, color: "#ffffff", permissions: Role::ADMIN_PERMISSIONS)
    owner_role = roles.create!(name: "Owner", position: 100, color: "#ffffff", permissions: Role::OWNER_PERMISSIONS)

    text_category = categories.create!(name: "Text Channels", position: 0)
    general = channels.create!(name: "general", channel_type: :text, position: 0, category: text_category)

    # Set welcome channel to #general
    update_column(:welcome_channel_id, general.id)

    server_memberships.create!(user: owner, role: owner_role, joined_at: Time.current)
    invites.create!(creator: owner)
  end
end
