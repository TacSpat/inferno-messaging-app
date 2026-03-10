# Perceptual image hashing using dHash (difference hash).
#
# dHash works by:
# 1. Resize image to 9x8 grayscale (9 wide so we get 8 horizontal diffs)
# 2. Compare each pixel to its right neighbor
# 3. Left > right = 1 bit, else 0 bit
# 4. Result: 64-bit hash that survives resizing, compression, minor edits
#
# Uses MiniMagick (available via image_processing gem / ActiveStorage).
#
class ImageHasher
  HASH_WIDTH = 9
  HASH_HEIGHT = 8

  # Compute dHash for an image file path or IO.
  # Returns hex string (16 chars = 64 bits) or nil on failure.
  def self.dhash(source)
    require "mini_magick"

    image = case source
    when String
      MiniMagick::Image.open(source)
    when ActiveStorage::Blob
      tempfile = Tempfile.new(["hash", ".#{source.filename.extension}"])
      tempfile.binmode
      source.download { |chunk| tempfile.write(chunk) }
      tempfile.rewind
      MiniMagick::Image.open(tempfile.path)
    else
      return nil
    end

    # Convert to 9x8 grayscale
    image.combine_options do |c|
      c.colorspace "Gray"
      c.resize "#{HASH_WIDTH}x#{HASH_HEIGHT}!"
      c.depth 8
    end

    # Get raw pixel values (8-bit grayscale)
    pixels = image.get_pixels("I") # "I" = intensity (grayscale)

    # If get_pixels doesn't support "I", fall back to extracting from RGB
    if pixels.nil? || pixels.empty?
      pixels = image.get_pixels.map { |row| row.map { |px| (px[0] * 0.299 + px[1] * 0.587 + px[2] * 0.114).round } }
    else
      pixels = pixels.map { |row| row.map { |px| px.is_a?(Array) ? px[0] : px } }
    end

    # Build hash: compare each pixel to its right neighbor
    bits = []
    pixels.each do |row|
      (HASH_WIDTH - 1).times do |x|
        bits << (row[x] > row[x + 1] ? 1 : 0)
      end
    end

    # Convert 64 bits to hex
    bits.each_slice(4).map { |nibble| nibble.join.to_i(2).to_s(16) }.join
  rescue => e
    Rails.logger.warn("[ImageHasher] Failed to hash image: #{e.message}")
    nil
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  # Compute dHash for a video by extracting the first frame via ffmpeg.
  # Returns nil if ffmpeg is not available.
  def self.dhash_video(source_path)
    return nil unless ffmpeg_available?

    tempfile = Tempfile.new(["frame", ".png"])
    system("ffprobe", "-version", out: File::NULL, err: File::NULL) # warm up

    success = system(
      "ffmpeg", "-i", source_path,
      "-vframes", "1", "-f", "image2",
      "-y", tempfile.path,
      out: File::NULL, err: File::NULL
    )

    return nil unless success && File.size(tempfile.path) > 0
    dhash(tempfile.path)
  rescue => e
    Rails.logger.warn("[ImageHasher] Failed to hash video: #{e.message}")
    nil
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  def self.ffmpeg_available?
    @ffmpeg_available = system("which", "ffmpeg", out: File::NULL, err: File::NULL) if @ffmpeg_available.nil?
    @ffmpeg_available
  end

  # Hash all images/videos attached to a message. Returns array of
  # { hash_value:, hash_type:, media_type:, original_filename: }
  def self.hash_message_attachments(message)
    return [] unless message.files.attached?

    results = []
    message.files.each do |attachment|
      blob = attachment.blob
      if blob.image?
        hash = dhash(blob)
        results << { hash_value: hash, hash_type: "dhash", media_type: "image", original_filename: blob.filename.to_s } if hash
      elsif blob.video?
        # Download to temp file for ffmpeg
        tempfile = Tempfile.new(["video", ".#{blob.filename.extension}"])
        tempfile.binmode
        blob.download { |chunk| tempfile.write(chunk) }
        tempfile.rewind
        hash = dhash_video(tempfile.path)
        results << { hash_value: hash, hash_type: "dhash", media_type: "video_frame", original_filename: blob.filename.to_s } if hash
        tempfile.close
        tempfile.unlink
      end
    end

    results
  end
end
