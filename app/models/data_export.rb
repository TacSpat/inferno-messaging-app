class DataExport < ApplicationRecord
  has_paper_trail

  STATUSES = %w[pending processing completed failed expired].freeze
  EXPORT_TYPES = %w[full messages profile].freeze

  belongs_to :user
  belongs_to :requested_by, class_name: "User"

  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :export_type, presence: true, inclusion: { in: EXPORT_TYPES }

  scope :pending, -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }

  def process!
    update!(status: "processing")
  end

  def complete!(path)
    update!(status: "completed", file_path: path, expires_at: 7.days.from_now)
  end

  def fail!
    update!(status: "failed")
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end
end
