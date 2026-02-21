require "net/http"
require "digest"

# Blossom client for content-addressable file storage (BUD-01).
# Uploads files to configured Blossom servers and returns URLs.
# Files are addressed by SHA-256 hash.
class BlossomClientService
  class UploadError < StandardError; end

  # Upload a file to configured Blossom servers.
  # Returns the URL of the uploaded file on the first successful server.
  def self.upload(file_path_or_io, content_type: "application/octet-stream", filename: nil)
    data = file_path_or_io.respond_to?(:read) ? file_path_or_io.read : File.binread(file_path_or_io)
    sha256 = Digest::SHA256.hexdigest(data)

    server_urls = blossom_server_urls
    raise UploadError, "No Blossom servers configured" if server_urls.empty?

    errors = []
    server_urls.each do |base_url|
      begin
        url = upload_to_server(base_url, data, sha256, content_type)
        return { url: url, sha256: sha256, size: data.bytesize }
      rescue => e
        errors << "#{base_url}: #{e.message}"
        next
      end
    end

    raise UploadError, "Upload failed on all servers: #{errors.join('; ')}"
  end

  # Download a file by SHA-256 hash from configured Blossom servers.
  # Returns the raw file data, or nil if not found.
  def self.download(sha256)
    server_urls = blossom_server_urls
    return nil if server_urls.empty?

    server_urls.each do |base_url|
      begin
        data = download_from_server(base_url, sha256)
        return data if data
      rescue => e
        Rails.logger.warn("Blossom download failed from #{base_url}: #{e.message}")
        next
      end
    end

    nil
  end

  # Check if a file exists on any Blossom server.
  def self.exists?(sha256)
    blossom_server_urls.any? do |base_url|
      check_exists(base_url, sha256)
    end
  end

  # Build the URL for a file on a given Blossom server.
  def self.url_for(sha256, base_url: nil)
    base_url ||= blossom_server_urls.first
    return nil unless base_url
    "#{base_url.chomp('/')}/#{sha256}"
  end

  private

  DEFAULT_BLOSSOM_SERVERS = %w[
    https://blossom.primal.net
    https://nostr.build
  ].freeze

  def self.blossom_server_urls
    config = LocalConfig.current
    urls = config.respond_to?(:blossom_server_urls) ? config.blossom_server_urls : nil
    urls = Array(urls).select(&:present?)
    urls.any? ? urls : DEFAULT_BLOSSOM_SERVERS
  end

  def self.upload_to_server(base_url, data, sha256, content_type)
    uri = URI("#{base_url.chomp('/')}/upload")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 60

    request = Net::HTTP::Put.new(uri.path)
    request["Content-Type"] = content_type
    request["X-SHA-256"] = sha256
    request.body = data

    # BUD-01 auth: sign the upload with the owner's Nostr key
    owner = User.owner
    if owner&.nostr_private_key.present?
      auth_event = build_auth_event(owner, sha256, "upload")
      request["Authorization"] = "Nostr #{Base64.strict_encode64(auth_event.to_json)}"
    end

    response = http.request(request)

    unless response.is_a?(Net::HTTPSuccess)
      raise UploadError, "HTTP #{response.code}: #{response.body}"
    end

    result = JSON.parse(response.body) rescue {}
    result["url"] || "#{base_url.chomp('/')}/#{sha256}"
  end

  def self.download_from_server(base_url, sha256)
    uri = URI("#{base_url.chomp('/')}/#{sha256}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    response = http.request(Net::HTTP::Get.new(uri.path))
    return response.body if response.is_a?(Net::HTTPSuccess)

    nil
  end

  def self.check_exists(base_url, sha256)
    uri = URI("#{base_url.chomp('/')}/#{sha256}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5

    response = http.request(Net::HTTP::Head.new(uri.path))
    response.is_a?(Net::HTTPSuccess)
  rescue
    false
  end

  def self.build_auth_event(user, sha256, action)
    event_data = {
      pubkey: user.nostr_public_key,
      created_at: Time.now.to_i,
      kind: 24242,
      tags: [
        ["t", action],
        ["x", sha256],
        ["expiration", (Time.now.to_i + 300).to_s]
      ],
      content: "Upload #{sha256}"
    }

    serialized = [0, event_data[:pubkey], event_data[:created_at], event_data[:kind], event_data[:tags], event_data[:content]]
    event_data[:id] = Digest::SHA256.hexdigest(JSON.generate(serialized))

    schnorr_key = Nostr::Key.new(user.nostr_private_key)
    event_data[:sig] = schnorr_key.sign(event_data[:id])

    event_data
  end
end
