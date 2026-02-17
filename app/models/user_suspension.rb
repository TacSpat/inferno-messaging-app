class UserSuspension < ApplicationRecord
  has_paper_trail

  SUSPENSION_TYPES = %w[temporary permanent].freeze
  REASON_CATEGORIES = %w[csam spam harassment illegal admin_action federation_received].freeze

  belongs_to :user
  belongs_to :suspended_by, class_name: "User", optional: true
  belongs_to :lifted_by, class_name: "User", optional: true

  validates :suspension_type, presence: true, inclusion: { in: SUSPENSION_TYPES }
  validates :reason_category, inclusion: { in: REASON_CATEGORIES }, allow_nil: true

  scope :active, -> { where(lifted_at: nil) }
  scope :lifted, -> { where.not(lifted_at: nil) }
  scope :expired, -> { active.where("expires_at < ?", Time.current) }
  scope :by_category, ->(cat) { where(reason_category: cat) }
  scope :auto_triggered, -> { where(auto_triggered: true) }

  def active?
    lifted_at.nil?
  end

  def permanent?
    suspension_type == "permanent"
  end

  def expired?
    !permanent? && expires_at.present? && expires_at < Time.current
  end

  def lift!(admin, reason: nil)
    update!(lifted_at: Time.current, lifted_by: admin, lift_reason: reason)
    user.update!(suspended_at: nil) unless user.user_suspensions.active.where.not(id: id).exists?
  end
end
