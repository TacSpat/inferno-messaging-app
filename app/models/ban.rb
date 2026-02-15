class Ban < ApplicationRecord
  belongs_to :server
  has_paper_trail
  belongs_to :user
  belongs_to :banned_by, class_name: "User"

  validates :user_id, uniqueness: { scope: :server_id }

  after_create :remove_membership

  private

  def remove_membership
    server.server_memberships.where(user: user).destroy_all
  end
end
