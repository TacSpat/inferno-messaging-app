require "net/http"
require "digest"
require "fileutils"

# Downloads and caches remote assets (emojis, stickers, images) locally
# so they survive when the sender goes offline.
#
# Files are stored in public/cached_assets/<sha256_hash>.<ext>
# and served directly by the web server with no database overhead.
#
class RemoteAssetCache
  CACHE_DIR = Rails.root.join("public", "cached_assets")
  MAX_SIZE  = 10.megabytes
  TIMEOUT   = 5 # seconds

  # Returns a local path like "/cached_assets/abc123.png"
  # or nil if the download fails.
  def self.cache(remote_url)
    return nil if remote_url.blank?

    uri = URI.parse(remote_url) rescue nil
    return nil unless uri&.host

    hash = Digest::SHA256.hexdigest(remote_url)
    ext = File.extname(uri.path).presence || ".png"
    filename = "#{hash}#{ext}"
    local_path = "/cached_assets/#{filename}"
    full_path = CACHE_DIR.join(filename)

    # Already cached
    return local_path if File.exist?(full_path)

    # Download
    FileUtils.mkdir_p(CACHE_DIR)
    response = fetch_with_redirects(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)
    return nil if response.body.bytesize > MAX_SIZE

    File.binwrite(full_path, response.body)
    local_path
  rescue => e
    Rails.logger.warn("[RemoteAssetCache] Failed to cache #{remote_url}: #{e.message}")
    nil
  end

  # Cache multiple URLs in one call. Returns a hash of { remote_url => local_path }.
  def self.cache_all(urls)
    urls.each_with_object({}) do |url, map|
      local = cache(url)
      map[url] = local if local
    end
  end

  private

  def self.fetch_with_redirects(uri, limit = 3)
    return nil if limit <= 0

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    response = http.request(Net::HTTP::Get.new(uri))
    if response.is_a?(Net::HTTPRedirection) && response["location"]
      fetch_with_redirects(URI.parse(response["location"]), limit - 1)
    else
      response
    end
  end
end
