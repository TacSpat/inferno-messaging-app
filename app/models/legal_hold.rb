class LegalHold < ApplicationRecord
  has_paper_trail

  belongs_to :holdable, polymorphic: true
  belongs_to :placed_by, class_name: "User"

  validates :placed_at, presence: true

  scope :active, -> { where(active: true) }
  scope :lifted, -> { where(active: false) }

  def lift!
    update!(active: false, lifted_at: Time.current)
  end

  def self.held?(record)
    active.where(holdable: record).exists?
  end
end
