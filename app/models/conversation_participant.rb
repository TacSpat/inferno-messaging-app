class ConversationParticipant < ApplicationRecord
  belongs_to :conversation
  belongs_to :user

  validates :user_id, uniqueness: { scope: :conversation_id }

  scope :accepted, -> { where(accepted: true) }
  scope :pending, -> { where(accepted: false) }

  def unread_count
    scope = conversation.messages.where.not(user: user)
    if last_read_at.present?
      scope.where("created_at > ?", last_read_at).count
    else
      scope.count
    end
  end

  def mark_read!
    update!(last_read_at: Time.current)
  end
end
