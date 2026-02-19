class Friendship < ApplicationRecord
  belongs_to :user
  belongs_to :friend, class_name: "User"

  enum :status, { pending: 0, accepted: 1, declined: 2, ignored: 3 }

  validates :friend_id, uniqueness: { scope: :user_id }
  validate :not_self
  validate :not_blocked

  after_commit :publish_nostr_contacts, if: :should_publish_contacts?

  # Accept a friend request (creates the reverse record too)
  def accept!
    transaction do
      update!(status: :accepted)
      Friendship.find_or_create_by!(user: friend, friend: user) do |f|
        f.status = :accepted
      end
    end
    notify_remote_acceptance if federation_callback_token.present? && user.remote?
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

  def should_publish_contacts?
    accepted? && !user.remote? && user.nostr_public_key.present?
  end

  def publish_nostr_contacts
    NostrPublishJob.perform_later(user_id, :contacts)
  end

  def notify_remote_acceptance
    home = user.remote_user_detail&.home_instance
    return unless home

    FederationService.notify_friend_response(
      instance_url: FederationService.normalize_instance_url_for_storage(home),
      callback_token: federation_callback_token,
      status: "accepted",
      responder: friend
    )
  rescue => e
    Rails.logger.warn("Federation: failed to notify remote acceptance: #{e.message}")
  end
end
