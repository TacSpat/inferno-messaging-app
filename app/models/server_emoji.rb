class ServerEmoji < ApplicationRecord
  include HasPublicId

  belongs_to :server
  belongs_to :creator, class_name: "User"
  has_one_attached :image

  validates :name, presence: true, length: { maximum: 32 },
            format: { with: /\A[a-z0-9_]+\z/, message: "can only contain lowercase letters, numbers, and underscores" },
            uniqueness: { scope: :server_id, case_sensitive: false }
  validates :image, presence: true, on: :create
  validate :acceptable_image
  validate :within_emoji_limit, on: :create

  MAX_EMOJIS_PER_SERVER = 50
  MAX_FILE_SIZE = 256.kilobytes

  def image_url
    return nil unless image.attached?
    Rails.application.routes.url_helpers.rails_blob_path(image, only_path: true)
  end

  private

  def acceptable_image
    return unless image.attached?

    unless image.content_type.in?(%w[image/png image/gif image/webp])
      errors.add(:image, "must be a PNG, GIF, or WebP")
    end

    if image.byte_size > MAX_FILE_SIZE
      errors.add(:image, "must be less than 256KB")
    end
  end

  def within_emoji_limit
    if server && server.server_emojis.count >= MAX_EMOJIS_PER_SERVER
      errors.add(:base, "This server has reached its emoji limit (#{MAX_EMOJIS_PER_SERVER})")
    end
  end
end
