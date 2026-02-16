class RemoteConversationReference < ApplicationRecord
  belongs_to :user

  validates :remote_instance_url, presence: true
  validates :remote_conversation_id, presence: true
  validates :remote_conversation_id, uniqueness: { scope: [:user_id, :remote_instance_url] }

  scope :ordered, -> { order(last_message_at: :desc, created_at: :desc) }

  def remote_conversation_url
    "#{remote_instance_url}/conversations"
  end

  def display_name
    name.presence || other_display_name.presence || other_username.presence || "Unknown"
  end

  def instance_domain
    URI.parse(remote_instance_url).host
  rescue URI::InvalidURIError
    remote_instance_url
  end
end
