class Call < ApplicationRecord
  include HasPublicId
  belongs_to :conversation
  belongs_to :initiated_by, class_name: "User"
  has_many :call_participants, dependent: :destroy

  scope :active, -> { where(status: %w[ringing active]) }

  def room_name
    "dm-#{conversation.public_id}-#{public_id}"
  end

  def duration
    started_at && ended_at ? (ended_at - started_at).to_i : nil
  end

  def joinable?
    status.in?(%w[ringing active])
  end
end
