class MembershipRole < ApplicationRecord
  belongs_to :server_membership
  belongs_to :role

  validates :role_id, uniqueness: { scope: :server_membership_id }
end
