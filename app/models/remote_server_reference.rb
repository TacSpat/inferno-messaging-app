class RemoteServerReference < ApplicationRecord
  belongs_to :user

  validates :remote_instance_url, presence: true
  validates :remote_server_id, presence: true
  validates :remote_server_id, uniqueness: { scope: [:user_id, :remote_instance_url] }

  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  def remote_server_url
    return nil unless invite_code.present?
    base = "#{remote_instance_url}/invite/#{invite_code}"
    home_domain = Rails.application.config.x.instance_domain
    home_domain.present? ? "#{base}?from=#{home_domain}" : base
  end

  def instance_domain
    URI.parse(remote_instance_url).host
  rescue URI::InvalidURIError
    remote_instance_url
  end
end
