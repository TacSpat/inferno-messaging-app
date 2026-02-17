module Suspendable
  extend ActiveSupport::Concern

  included do
    scope :active_users, -> { where(suspended_at: nil) }
    scope :suspended_users, -> { where.not(suspended_at: nil) }
  end

  def suspended?
    suspended_at.present?
  end

  def active_for_authentication?
    super && !suspended?
  end

  def inactive_message
    suspended? ? :suspended : super
  end
end
