module HasPublicId
  extend ActiveSupport::Concern

  included do
    before_validation :generate_public_id, on: :create
  end

  def to_param
    public_id
  end

  private

  def generate_public_id
    self.public_id ||= loop {
      pid = SecureRandom.alphanumeric(12)
      break pid unless self.class.exists?(public_id: pid)
    }
  end
end
