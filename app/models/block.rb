class Block < ApplicationRecord
  belongs_to :blocker, class_name: "User"
  belongs_to :blocked, class_name: "User"

  validates :blocked_id, uniqueness: { scope: :blocker_id }
  validate :not_self

  # Blocking removes any existing friendship
  after_create :remove_friendships

  private

  def not_self
    errors.add(:blocked, "can't block yourself") if blocker_id == blocked_id
  end

  def remove_friendships
    Friendship.where(user_id: blocker_id, friend_id: blocked_id).destroy_all
    Friendship.where(user_id: blocked_id, friend_id: blocker_id).destroy_all
  end
end
