class Conversation < ApplicationRecord
  include HasPublicId
  enum :kind, { direct: 0, group_chat: 1 }

  has_many :conversation_participants, dependent: :destroy
  has_many :participants, through: :conversation_participants, source: :user
  has_many :contact_participants, -> { where.not(contact_id: nil) }, class_name: "ConversationParticipant"
  has_many :messages, -> { where(hidden_at: nil) }, dependent: :destroy
  has_many :all_messages, class_name: "Message", foreign_key: :conversation_id
  has_many :calls, dependent: :destroy
  has_one_attached :icon

  validates :name, length: { maximum: 100 }

  def effective_icon_url
    return nil unless icon.attached?
    icon.blob.metadata&.dig("blossom_url") ||
      Rails.application.routes.url_helpers.rails_blob_path(icon, only_path: true)
  end

  # Find or create a direct conversation with a counterparty identified by pubkey
  def self.find_or_create_by_pubkey(owner, counterparty_pubkey)
    conv = where(kind: :direct, counterparty_pubkey: counterparty_pubkey).first
    return conv if conv

    transaction do
      conv = create!(kind: :direct, counterparty_pubkey: counterparty_pubkey)
      conv.conversation_participants.create!(user: owner, accepted: true)
      conv
    end
  end

  def self.find_or_create_direct(user1, user2)
    conv = joins(:conversation_participants)
      .where(kind: :direct)
      .where(conversation_participants: { user_id: user1.id })
      .joins("INNER JOIN conversation_participants cp2 ON cp2.conversation_id = conversations.id AND cp2.user_id = #{user2.id}")
      .first
    return conv if conv

    transaction do
      conv = create!(kind: :direct)
      conv.conversation_participants.create!(user: user1, accepted: true)
      accepted = user1.friends_with?(user2)
      conv.conversation_participants.create!(user: user2, accepted: accepted)
      conv
    end
  end

  def other_user(current_user)
    participants.where.not(id: current_user.id).first
  end

  # Returns the ConversationParticipant for the other side (works for both User and Contact participants)
  def other_participant(current_user)
    conversation_participants.detect { |cp| cp.user_id != current_user.id }
  end

  def display_name(current_user)
    if direct?
      other = other_user(current_user)
      other&.display_name.presence || other&.username || counterparty_display_name || "Unknown"
    else
      name.presence || conversation_participants
        .reject { |cp| cp.user_id == current_user.id }
        .map(&:display_name)
        .compact
        .join(", ")
    end
  end

  # Look up the Contact record for the counterparty pubkey
  def counterparty_contact
    return nil if counterparty_pubkey.blank?
    @counterparty_contact ||= Contact.find_by(pubkey: counterparty_pubkey)
  end

  # Display name for pubkey-only contacts (no local user record)
  def counterparty_display_name
    return nil if counterparty_pubkey.blank?
    # Try Contact record first
    contact = counterparty_contact
    return contact.effective_display_name if contact&.effective_display_name.present?
    # Truncated npub as fallback
    begin
      npub = Nostr::Bech32.encode_npub(counterparty_pubkey)
      "#{npub[0..12]}..."
    rescue
      "#{counterparty_pubkey[0..8]}..."
    end
  end

  def last_message
    messages.order(created_at: :desc).first
  end

  def accepted_by?(user)
    conversation_participants.find_by(user: user)&.accepted?
  end

  def message_request_for?(user)
    !accepted_by?(user)
  end
end
