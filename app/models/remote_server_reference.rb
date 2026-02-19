class RemoteServerReference < ApplicationRecord
  belongs_to :user
  belongs_to :server_folder, optional: true

  validates :remote_instance_url, presence: true
  validates :remote_server_id, presence: true
  validates :remote_server_id, uniqueness: { scope: [ :user_id, :remote_instance_url ] }

  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  # Filter out http:// duplicates when an https:// version of the same server exists
  scope :prefer_https, -> {
    where.not(
      "remote_instance_url LIKE 'http://%' AND EXISTS (" \
        "SELECT 1 FROM remote_server_references r2 " \
        "WHERE r2.user_id = remote_server_references.user_id " \
        "AND r2.remote_server_id = remote_server_references.remote_server_id " \
        "AND r2.remote_instance_url LIKE 'https://%'" \
      ")"
    )
  }

  def remote_server_url
    "#{remote_instance_url}/servers/#{remote_server_id}"
  end

  def instance_domain
    URI.parse(remote_instance_url).host
  rescue URI::InvalidURIError
    remote_instance_url
  end
end
