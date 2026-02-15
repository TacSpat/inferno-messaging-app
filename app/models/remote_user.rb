class RemoteUser < ApplicationRecord
  include HasPublicId

  has_one :shadow_user, class_name: "User", foreign_key: :remote_user_detail_id, dependent: :destroy

  validates :nostr_public_key, presence: true, uniqueness: true
  validates :home_instance, presence: true
  validates :username, length: { maximum: 32 }, allow_blank: true

  before_validation :normalize_home_instance

  # Find or create a RemoteUser + shadow User pair from auth data
  def self.find_or_create_from_auth(public_key:, home_instance:, username: nil, display_name: nil, avatar_url: nil, bio: nil)
    remote_user = find_or_initialize_by(nostr_public_key: public_key)
    remote_user.home_instance = home_instance
    remote_user.username = username if username.present?
    remote_user.display_name = display_name if display_name.present?
    remote_user.avatar_url = avatar_url if avatar_url.present?
    remote_user.bio = bio if bio.present?
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
        public_id: SecureRandom.alphanumeric(12)
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

  private

  def normalize_home_instance
    self.home_instance = home_instance&.downcase&.strip
  end
end
