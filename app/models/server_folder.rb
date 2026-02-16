class ServerFolder < ApplicationRecord
  include HasPublicId

  belongs_to :user
  has_many :server_memberships, dependent: :nullify

  scope :ordered, -> { order(position: :asc) }

  validates :name, presence: true, length: { maximum: 50 }
  validates :color, format: { with: /\A#[0-9a-fA-F]{6}\z/ }, allow_blank: true
end
