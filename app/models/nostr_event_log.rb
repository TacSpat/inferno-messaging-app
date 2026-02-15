class NostrEventLog < ApplicationRecord
  belongs_to :message, optional: true
  belongs_to :channel, optional: true

  DIRECTIONS = %w[inbound outbound].freeze

  validates :event_id, presence: true, uniqueness: true
  validates :kind, presence: true
  validates :pubkey, presence: true
  validates :direction, presence: true, inclusion: { in: DIRECTIONS }

  scope :inbound, -> { where(direction: "inbound") }
  scope :outbound, -> { where(direction: "outbound") }

  def self.already_processed?(event_id)
    exists?(event_id: event_id)
  end
end
