class RemoteConversationReference < ApplicationRecord
  belongs_to :user

  validates :remote_instance_url, presence: true
  validates :remote_conversation_id, presence: true
  validates :remote_conversation_id, uniqueness: { scope: [ :user_id, :remote_instance_url ] }

  scope :ordered, -> { order(last_message_at: :desc, created_at: :desc) }

  # Filter out http:// duplicates when an https:// version of the same conversation exists
  scope :prefer_https, -> {
    where.not(
      "remote_instance_url LIKE 'http://%' AND EXISTS (" \
        "SELECT 1 FROM remote_conversation_references r2 " \
        "WHERE r2.user_id = remote_conversation_references.user_id " \
        "AND r2.remote_conversation_id = remote_conversation_references.remote_conversation_id " \
        "AND r2.remote_instance_url LIKE 'https://%'" \
      ")"
    )
  }

  def remote_conversation_url
    "#{remote_instance_url}/conversations/#{remote_conversation_id}"
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
