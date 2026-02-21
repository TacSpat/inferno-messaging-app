class RemoteMembershipRole < ApplicationRecord
  belongs_to :remote_member
  belongs_to :role

  validates :role_id, uniqueness: { scope: :remote_member_id }
end
