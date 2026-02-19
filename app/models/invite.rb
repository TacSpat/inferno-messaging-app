class Invite < ApplicationRecord
  belongs_to :server
  belongs_to :creator, class_name: "User"
  has_paper_trail

  validates :code, presence: true, uniqueness: true

  before_validation :generate_code, on: :create

  scope :active_invites, -> { where(active: true).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def maxed_out?
    max_uses.present? && uses_count >= max_uses
  end

  def usable?
    active? && !expired? && !maxed_out?
  end

  def increment_uses!
    increment!(:uses_count)
  end

  private

  def generate_code
    self.code ||= SecureRandom.alphanumeric(16)
  end
end
