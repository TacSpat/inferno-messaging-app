class Category < ApplicationRecord
  include HasPublicId
  include InstanceLimits
  belongs_to :server
  has_many :channels, dependent: :nullify

  validates :name, presence: true, length: { maximum: 100 }
  validate :within_category_limit, on: :create

  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  private

  def within_category_limit
    if server && instance_config.category_limit_reached_for?(server)
      errors.add(:base, "This server has reached its category limit (#{instance_config.max_categories_per_server})")
    end
  end
end
