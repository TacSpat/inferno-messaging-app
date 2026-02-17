class RemoteFriendReference < ApplicationRecord
  belongs_to :user

  validates :remote_instance_url, presence: true
  validates :friend_public_key, uniqueness: { scope: [ :user_id, :remote_instance_url ] }, allow_nil: true

  scope :ordered, -> { order(:friend_display_name, :friend_username) }
  scope :online, -> { where.not(online_state: "offline") }

  def display_name
    friend_display_name.presence || friend_username.presence || "Unknown"
  end

  def instance_domain
    URI.parse(remote_instance_url).host
  rescue URI::InvalidURIError
    remote_instance_url
  end
end
