class ServerSticker < ApplicationRecord
  include HasPublicId

  belongs_to :server
  belongs_to :creator, class_name: "User"
  has_one_attached :image

  validates :name, presence: true, length: { maximum: 50 },
            uniqueness: { scope: :server_id, case_sensitive: false }
  validates :image, presence: true, on: :create
  validate :acceptable_image
  validate :within_sticker_limit, on: :create

  MAX_STICKERS_PER_SERVER = 30
  MAX_FILE_SIZE = 512.kilobytes

  def image_url
    return nil unless image.attached?
    Rails.application.routes.url_helpers.rails_blob_path(image, only_path: true)
  end

  def blossom_url
    return nil unless image.attached?
    image.blob.metadata&.dig("blossom_url")
  end

  private

  def acceptable_image
    return unless image.attached?

    unless image.content_type.in?(%w[image/png image/gif image/webp image/apng])
      errors.add(:image, "must be a PNG, GIF, WebP, or APNG")
    end

    if image.byte_size > MAX_FILE_SIZE
      errors.add(:image, "must be less than 512KB")
    end
  end

  def within_sticker_limit
    if server && server.server_stickers.count >= MAX_STICKERS_PER_SERVER
      errors.add(:base, "This server has reached its sticker limit (#{MAX_STICKERS_PER_SERVER})")
    end
  end
end
