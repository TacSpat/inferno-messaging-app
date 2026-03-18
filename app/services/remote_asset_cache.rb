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

  # Content-Type to file extension mapping
  MIME_TO_EXT = {
    "image/png"  => ".png",  "image/jpeg" => ".jpg", "image/gif"  => ".gif",
    "image/webp" => ".webp", "image/svg+xml" => ".svg", "image/avif" => ".avif",
    "video/mp4"  => ".mp4",  "video/webm" => ".webm", "video/quicktime" => ".mov",
    "audio/mpeg" => ".mp3",  "audio/ogg"  => ".ogg",  "audio/wav" => ".wav",
    "audio/webm" => ".weba", "audio/mp4"  => ".m4a",
  }.freeze

  # Returns a local path like "/cached_assets/abc123.png"
  # or nil if the download fails.
  def self.cache(remote_url)
    return nil if remote_url.blank?

    uri = URI.parse(remote_url) rescue nil
    return nil unless uri&.host

    hash = Digest::SHA256.hexdigest(remote_url)
    url_ext = File.extname(uri.path).presence

    # If URL has an extension, check cache immediately
    if url_ext
      filename = "#{hash}#{url_ext}"
      local_path = "/cached_assets/#{filename}"
      return local_path if File.exist?(CACHE_DIR.join(filename))
    else
      # Extensionless URL (e.g. blossom) — check if any cached file exists for this hash
      existing = Dir.glob(CACHE_DIR.join("#{hash}.*")).first
      if existing
        return "/cached_assets/#{File.basename(existing)}"
      end
    end

    # Check cache size limit before downloading
    evict_if_over_limit

    # Download
    FileUtils.mkdir_p(CACHE_DIR)
    response = fetch_with_redirects(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)
    return nil if response.body.bytesize > MAX_SIZE

    # Determine extension: prefer URL extension, fall back to Content-Type header
    ext = url_ext || ext_from_content_type(response["content-type"]) || ".bin"
    filename = "#{hash}#{ext}"
    local_path = "/cached_assets/#{filename}"

    File.binwrite(CACHE_DIR.join(filename), response.body)
    local_path
  rescue => e
    Rails.logger.warn("[RemoteAssetCache] Failed to cache #{remote_url}: #{e.message}")
    nil
  end

  # Returns the local cached path if the file already exists on disk,
  # without making any HTTP requests. Used for fast lookups in views.
  def self.cached_path(remote_url)
    return nil if remote_url.blank?

    uri = URI.parse(remote_url) rescue nil
    return nil unless uri&.host

    hash = Digest::SHA256.hexdigest(remote_url)
    url_ext = File.extname(uri.path).presence

    if url_ext
      full = CACHE_DIR.join("#{hash}#{url_ext}")
      return "/cached_assets/#{hash}#{url_ext}" if File.exist?(full)
    else
      # Extensionless — find any cached file matching this hash
      existing = Dir.glob(CACHE_DIR.join("#{hash}.*")).first
      return "/cached_assets/#{File.basename(existing)}" if existing
    end

    nil
  end

  # Cache multiple URLs in one call. Returns a hash of { remote_url => local_path }.
  def self.cache_all(urls)
    urls.each_with_object({}) do |url, map|
      local = cache(url)
      map[url] = local if local
    end
  end

  # Evict oldest cached files when over the configured max_cache_size_mb.
  # Deletes least-recently-accessed files until usage is under 90% of the limit,
  # leaving headroom so we don't evict on every single cache call.
  def self.evict_if_over_limit
    config = LocalConfig.current
    return if config.max_cache_size_mb.zero?

    max_bytes = config.max_cache_size_mb * 1024 * 1024
    return unless CACHE_DIR.exist?

    files = Dir.glob(CACHE_DIR.join("**", "*")).select { |f| File.file?(f) }
    total = files.sum { |f| File.size(f) rescue 0 }
    return if total <= max_bytes

    target = (max_bytes * 0.9).to_i
    # Sort by access time (oldest first)
    sorted = files.sort_by { |f| File.atime(f) rescue File.mtime(f) }
    sorted.each do |f|
      break if total <= target
      size = File.size(f) rescue 0
      File.delete(f) rescue nil
      total -= size
    end
  rescue => e
    Rails.logger.warn("[RemoteAssetCache] Cache eviction failed: #{e.message}")
  end

  private

  def self.ext_from_content_type(content_type)
    return nil if content_type.blank?
    mime = content_type.split(";").first&.strip&.downcase
    MIME_TO_EXT[mime]
  end

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
