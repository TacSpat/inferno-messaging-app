class ConversationParticipant < ApplicationRecord
  belongs_to :conversation
  belongs_to :user, optional: true
  belongs_to :contact, optional: true

  validate :user_or_contact_present

  scope :accepted, -> { where(accepted: true) }
  scope :pending, -> { where(accepted: false) }

  # Unified accessor: returns the User or Contact backing this participant
  def profile
    user || contact
  end

  def pubkey
    user&.nostr_public_key || contact&.pubkey
  end

  def display_name
    if user
      user.display_name.presence || user.username
    elsif contact
      contact.effective_display_name
    end
  end

  def avatar_url
    if user
      user.effective_avatar_url
    elsif contact
      contact.avatar_url
    end
  end

  def online?
    if user
      user.online_state != "offline"
    elsif contact
      contact.online?
    end
  end

  def unread_count
    scope = conversation.messages
    scope = user ? scope.where.not(user: user) : scope
    if last_read_at.present?
      scope.where("created_at > ?", last_read_at).count
    else
      scope.count
    end
  end

  def mark_read!
    update!(last_read_at: Time.current)
  end

  private

  def user_or_contact_present
    if user_id.blank? && contact_id.blank?
      errors.add(:base, "Must have either a user or contact")
    end
  end
end
