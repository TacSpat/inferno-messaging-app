class RemoteFriendReference < ApplicationRecord
  belongs_to :user

  validates :remote_instance_url, presence: true
  validates :friend_public_key, uniqueness: { scope: [ :user_id, :remote_instance_url ] }, allow_nil: true

  scope :ordered, -> { order(:friend_display_name, :friend_username) }
  scope :online, -> { where.not(online_state: "offline") }

  # Filter out http:// duplicates when an https:// version of the same friend exists
  scope :prefer_https, -> {
    where.not(
      "remote_instance_url LIKE 'http://%' AND EXISTS (" \
        "SELECT 1 FROM remote_friend_references r2 " \
        "WHERE r2.user_id = remote_friend_references.user_id " \
        "AND r2.friend_public_key = remote_friend_references.friend_public_key " \
        "AND r2.remote_instance_url LIKE 'https://%'" \
      ")"
    )
  }

  def display_name
    friend_display_name.presence || friend_username.presence || "Unknown"
  end

  def instance_domain
    URI.parse(remote_instance_url).host
  rescue URI::InvalidURIError
    remote_instance_url
  end
end
