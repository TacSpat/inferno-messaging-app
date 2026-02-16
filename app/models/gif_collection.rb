class GifCollection < ApplicationRecord
  include HasPublicId

  belongs_to :user
  has_many :gif_favorites, dependent: :destroy

  validates :name, presence: true, length: { maximum: 50 },
            uniqueness: { scope: :user_id, case_sensitive: false }
  validate :within_collection_limit, on: :create

  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  MAX_COLLECTIONS_PER_USER = 20

  def self.default_for(user)
    user.gif_collections.find_or_create_by!(name: "Favorites") do |c|
      c.position = 0
    end
  end

  private

  def within_collection_limit
    if user && user.gif_collections.count >= MAX_COLLECTIONS_PER_USER
      errors.add(:base, "You can have at most #{MAX_COLLECTIONS_PER_USER} collections")
    end
  end
end
