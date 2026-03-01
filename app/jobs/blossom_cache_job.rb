require "net/http"
require "digest"

# Download and cache Blossom files from external servers.
# Cached files are stored in the local Blossom directory and served by the local Blossom server.
class BlossomCacheJob < ApplicationJob
  queue_as :low_priority

  BLOSSOM_DIR = Rails.root.join("storage", "blossom")
  MAX_CACHE_SIZE = 5.gigabytes # Default cache limit
  MAX_FILE_SIZE = 100.megabytes # Skip files larger than this

  def perform(url)
    sha256 = extract_sha256(url)
    return unless sha256

    # Skip if already cached
    path = BLOSSOM_DIR.join(sha256)
    return if File.exist?(path)

    # Enforce cache size limit
    enforce_cache_limit

    # Download the file
    data = download(url)
    return unless data
    return if data.bytesize > MAX_FILE_SIZE

    # Verify hash
    actual_hash = Digest::SHA256.hexdigest(data)
    unless actual_hash == sha256
      Rails.logger.warn("[BlossomCache] Hash mismatch for #{url}: expected #{sha256}, got #{actual_hash}")
      return
    end

    # Store
    FileUtils.mkdir_p(BLOSSOM_DIR)
    File.binwrite(path, data)
    Rails.logger.info("[BlossomCache] Cached #{sha256} (#{data.bytesize} bytes)")
  rescue => e
    Rails.logger.warn("[BlossomCache] Failed to cache #{url}: #{e.message}")
  end

  private

  def extract_sha256(url)
    # Extract SHA-256 hash from Blossom URLs like https://example.com/blossom/abc123...
    match = url.to_s.match(%r{/([0-9a-f]{64})(?:\.\w+)?$})
    match ? match[1] : nil
  end

  def download(url)
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 60

    response = http.request(Net::HTTP::Get.new(uri.request_uri))
    response.is_a?(Net::HTTPSuccess) ? response.body : nil
  end

  def enforce_cache_limit
    return unless Dir.exist?(BLOSSOM_DIR)

    files = Dir.glob(BLOSSOM_DIR.join("*")).map { |f| [ f, File.mtime(f), File.size(f) ] }
    total = files.sum(&:last)

    return if total < MAX_CACHE_SIZE

    # LRU eviction — delete oldest files until under limit
    files.sort_by! { |_path, mtime, _size| mtime }
    files.each do |path, _mtime, size|
      break if total < MAX_CACHE_SIZE * 0.8 # Evict down to 80%
      File.delete(path) rescue nil
      total -= size
      Rails.logger.info("[BlossomCache] Evicted #{File.basename(path)}")
    end
  end
end
