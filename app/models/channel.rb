class Channel < ApplicationRecord
  include HasPublicId
  belongs_to :server
  belongs_to :category, optional: true
  has_paper_trail
  has_many :messages, dependent: :destroy
  has_many :channel_reads, dependent: :destroy

  def unread_for?(user)
    last_message_at = messages.maximum(:created_at)
    return false unless last_message_at
    read = channel_reads.find_by(user: user)
    return true unless read
    read.last_read_at < last_message_at
  end

  enum :channel_type, { text: 0, voice: 1, announcement: 2 }

  validates :name, presence: true, length: { maximum: 100 },
            format: { with: /\A[a-z0-9_-]+\z/, message: "lowercase letters, numbers, hyphens, underscores only" }
  validates :channel_type, presence: true

  scope :ordered, -> { order(position: :asc, created_at: :asc) }
  scope :uncategorized, -> { where(category_id: nil) }
end
