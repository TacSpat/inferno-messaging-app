class RemoteUser < ApplicationRecord
  include HasPublicId

  has_one :shadow_user, class_name: "User", foreign_key: :remote_user_detail_id, dependent: :destroy

  validates :nostr_public_key, presence: true, uniqueness: true
  validates :home_instance, presence: true
  validates :username, length: { maximum: 32 }, allow_blank: true

  before_validation :normalize_home_instance

  # Find or create a RemoteUser + shadow User pair from auth data
  def self.find_or_create_from_auth(public_key:, home_instance:, username: nil, display_name: nil, avatar_url: nil, bio: nil, profile_color: nil, discriminator: nil)
    remote_user = find_or_initialize_by(nostr_public_key: public_key)
    remote_user.home_instance = home_instance
    remote_user.username = username if username.present?
    remote_user.display_name = display_name if display_name.present?
    remote_user.avatar_url = avatar_url if avatar_url.present?
    remote_user.bio = bio if bio.present?
    remote_user.profile_color = profile_color if profile_color.present?
    remote_user.discriminator = discriminator if discriminator.present?
    remote_user.last_verified_at = Time.current
    remote_user.save!

    # Ensure shadow user exists
    unless remote_user.shadow_user
      shadow_username = username.presence || "remote_#{public_key[0..7]}"
      shadow = User.new(
        username: shadow_username,
        display_name: display_name.presence || shadow_username,
        email: "nostr+#{public_key[0..15]}@#{home_instance}",
        password: SecureRandom.hex(32),
        remote: true,
        remote_user_detail: remote_user,
        public_id: SecureRandom.alphanumeric(12),
        profile_color: remote_user.profile_color
      )
      # Skip confirmation for remote users
      shadow.skip_confirmation!
      shadow.save!(validate: false)
    end

    remote_user
  end

  def nip05_identifier
    return nil if username.blank?
    "#{username.downcase}@#{home_instance}"
  end

  def sync_from_profile_data(data)
    # Update RemoteUser cached fields
    self.avatar_url = data["avatar_url"] if data["avatar_url"].present?
    self.banner_url = data["banner_url"] if data["banner_url"].present?
    self.bio = data["bio"] if data.key?("bio")
    self.profile_color = data["profile_color"] if data.key?("profile_color")
    self.profile_color_2 = data["profile_color_2"] if data.key?("profile_color_2")
    self.banner_offset_y = data["banner_offset_y"] if data.key?("banner_offset_y")
    self.status = data["status"] if data.key?("status")
    self.status_emoji = data["status_emoji"] if data.key?("status_emoji")
    self.discriminator = data["discriminator"] if data["discriminator"].present?
    self.display_name = data["display_name"] if data["display_name"].present?
    self.username = data["username"] if data["username"].present?
    self.last_profile_sync_at = Time.current
    save!

    # Sync display fields to shadow user
    if shadow_user
      attrs = {
        display_name: data["display_name"].presence || shadow_user.display_name,
        bio: data["bio"],
        profile_color: data["profile_color"],
        profile_color_2: data["profile_color_2"],
        banner_offset_y: data["banner_offset_y"],
        status: data["status"],
        status_emoji: data["status_emoji"]
      }
      attrs[:email] = data["email"] if data["email"].present?
      shadow_user.update!(attrs)
    end
  end

  private

  def normalize_home_instance
    self.home_instance = home_instance&.downcase&.strip
  end
end
