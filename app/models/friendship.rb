class Friendship < ApplicationRecord
  belongs_to :user
  belongs_to :friend, class_name: "User"

  enum :status, { pending: 0, accepted: 1, declined: 2 }

  validates :friend_id, uniqueness: { scope: :user_id }
  validate :not_self
  validate :not_blocked

  # Accept a friend request (creates the reverse record too)
  def accept!
    transaction do
      update!(status: :accepted)
      Friendship.find_or_create_by!(user: friend, friend: user) do |f|
        f.status = :accepted
      end
    end
  end

  private

  def not_self
    errors.add(:friend, "can't be yourself") if user_id == friend_id
  end

  def not_blocked
    if Block.exists?(blocker_id: friend_id, blocked_id: user_id) ||
       Block.exists?(blocker_id: user_id, blocked_id: friend_id)
      errors.add(:friend, "is blocked")
    end
  end
end
