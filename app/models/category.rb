class Category < ApplicationRecord
  include HasPublicId
  has_paper_trail
  belongs_to :server
  has_many :channels, dependent: :nullify

  validates :name, presence: true, length: { maximum: 100 }

  scope :ordered, -> { order(position: :asc, created_at: :asc) }
end
