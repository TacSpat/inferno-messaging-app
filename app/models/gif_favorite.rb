class GifFavorite < ApplicationRecord
  include HasPublicId

  belongs_to :user
  belongs_to :gif_collection

  validates :tenor_gif_id, presence: true,
            uniqueness: { scope: [ :user_id, :gif_collection_id ], message: "already in this collection" }
  validates :tenor_url, presence: true
  validates :preview_url, presence: true
  validates :gif_url, presence: true
  validate :within_favorite_limit, on: :create

  scope :ordered, -> { order(position: :asc, created_at: :desc) }

  MAX_FAVORITES_PER_USER = 200

  private

  def within_favorite_limit
    if user && user.gif_favorites.count >= MAX_FAVORITES_PER_USER
      errors.add(:base, "You can have at most #{MAX_FAVORITES_PER_USER} saved GIFs")
    end
  end
end
