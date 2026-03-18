require "shellwords"

# Two-stage NSFW detection pipeline. Runs entirely on-device.
#
# Stage 1 (pre-filter): Marqo ViT-Tiny (0.7MB, 384x384)
#   Trained on photos + drawings + rule34 + memes.
#   Very sensitive — catches drawn NSFW but has false positives on
#   stylized characters with visible skin.
#   If score < 0.5 → image is safe, skip stage 2.
#
# Stage 2 (confirmation): TostAI FocalNet-Base (3.7MB, 224x224)
#   3-class: SAFE / QUESTIONABLE / UNSAFE.
#   More conservative — fewer false positives but misses some drawn NSFW.
#   Confirms the pre-filter's suspicion.
#
# Decision logic:
#   - Pre-filter < 50% NSFW → SAFE (skip stage 2)
#   - Pre-filter ≥ 50% → run stage 2
#     - Stage 2 UNSAFE ≥ 15% OR QUESTIONABLE+UNSAFE ≥ 25% → FLAG
#     - Stage 2 says SAFE with high confidence → override pre-filter → SAFE
#
class NsfwDetector
  # Stage 1: Marqo ViT-Tiny pre-filter
  PREFILTER_PATH = Rails.root.join("lib/models/nsfw_marqo.onnx")
  PREFILTER_SIZE = 384
  PREFILTER_THRESHOLD = 0.5

  # Stage 2: FocalNet confirmation
  CONFIRM_PATH = Rails.root.join("lib/models/nsfw_focalnet.onnx")
  CONFIRM_SIZE = 224
  # FocalNet labels: 0=SAFE, 1=QUESTIONABLE, 2=UNSAFE
  CONFIRM_UNSAFE_THRESHOLD = 0.15
  CONFIRM_COMBINED_THRESHOLD = 0.25

  # ImageNet normalization (FocalNet)
  IMAGENET_MEAN = [ 0.485, 0.456, 0.406 ].freeze
  IMAGENET_STD  = [ 0.229, 0.224, 0.225 ].freeze

  class << self
    def available?
      defined?(OnnxRuntime) && File.exist?(PREFILTER_PATH)
    end

    # Returns { safe: Float, nsfw: Float, stage: String }
    def classify(image_path)
      return { safe: 1.0, nsfw: 0.0, stage: "none" } unless available?

      # Stage 1: pre-filter
      pf = run_prefilter(image_path)
      return { safe: 1.0, nsfw: 0.0, stage: "none" } unless pf

      if pf[:nsfw] < PREFILTER_THRESHOLD
        return { safe: pf[:sfw], nsfw: pf[:nsfw], stage: "prefilter_pass" }
      end

      # Stage 2: confirmation (only if pre-filter flagged)
      if File.exist?(CONFIRM_PATH)
        cf = run_confirmation(image_path)
        if cf
          unsafe = cf[:unsafe]
          combined = cf[:questionable] + cf[:unsafe]

          if unsafe >= CONFIRM_UNSAFE_THRESHOLD || combined >= CONFIRM_COMBINED_THRESHOLD
            # Both stages agree — flag it
            return { safe: cf[:safe], nsfw: combined, stage: "confirmed" }
          elsif pf[:nsfw] >= 0.93 && combined > 0.08
            # Pre-filter is very confident AND confirmation isn't fully clean —
            # trust the pre-filter (handles mixed-content images where a nude
            # figure is partially obscured by a clothed one)
            return { safe: cf[:safe], nsfw: pf[:nsfw], stage: "prefilter_strong" }
          else
            # Stage 2 overrides — pre-filter was a false positive
            return { safe: cf[:safe], nsfw: combined, stage: "overridden" }
          end
        end
      end

      # No confirmation model — trust pre-filter alone at higher threshold
      if pf[:nsfw] >= 0.93
        { safe: pf[:sfw], nsfw: pf[:nsfw], stage: "prefilter_only" }
      else
        { safe: pf[:sfw], nsfw: pf[:nsfw], stage: "prefilter_uncertain" }
      end
    rescue => e
      Rails.logger.error("[NsfwDetector] Classification failed: #{e.message}")
      { safe: 1.0, nsfw: 0.0, stage: "error" }
    end

    def explicit?(image_path, threshold: 0.7)
      return false unless available?
      result = classify(image_path)
      case result[:stage]
      when "confirmed", "prefilter_strong"
        true
      when "overridden", "prefilter_pass"
        false
      when "prefilter_only"
        result[:nsfw] >= threshold
      else
        false
      end
    end

    def video_explicit?(video_path, threshold: 0.7)
      return false unless available? && ffmpeg_available?
      frames = extract_video_frames(video_path)
      result = frames.any? { |f| explicit?(f, threshold: threshold) }
      frames.each { |f| File.delete(f) rescue nil }
      result
    rescue => e
      Rails.logger.error("[NsfwDetector] Video check failed: #{e.message}")
      false
    end

    def gif_explicit?(gif_path, threshold: 0.7)
      return false unless available?
      frames = extract_gif_frames(gif_path)
      result = frames.any? { |f| explicit?(f, threshold: threshold) }
      frames.each { |f| File.delete(f) rescue nil unless f == gif_path }
      result
    rescue => e
      Rails.logger.error("[NsfwDetector] GIF check failed: #{e.message}")
      false
    end

    def any_explicit?(message, threshold: 0.7)
      return false unless available?
      return false unless message.files.attached?

      message.files.any? do |file|
        Tempfile.create([ "nsfw", File.extname(file.filename.to_s) ]) do |tmp|
          tmp.binmode
          tmp.write(file.download)
          tmp.rewind
          ct = file.content_type.to_s
          if ct == "image/gif"
            gif_explicit?(tmp.path, threshold: threshold)
          elsif ct.start_with?("video/")
            video_explicit?(tmp.path, threshold: threshold)
          elsif ct.start_with?("image/")
            explicit?(tmp.path, threshold: threshold)
          else
            false
          end
        end
      end
    rescue => e
      Rails.logger.error("[NsfwDetector] Batch check failed: #{e.message}")
      false
    end

    private

    # --- Stage 1: Marqo pre-filter ---

    def prefilter_model
      @prefilter_model ||= OnnxRuntime::Model.new(PREFILTER_PATH.to_s)
    end

    # Returns { nsfw: Float, sfw: Float } or nil
    def run_prefilter(image_path)
      input = preprocess(image_path, PREFILTER_SIZE, :vit)
      return nil unless input

      output = prefilter_model.predict({ "input" => input })
      logits = output["output"].first
      probs = softmax(logits)
      # Marqo labels: 0=NSFW, 1=SFW
      { nsfw: probs[0].to_f, sfw: probs[1].to_f }
    rescue => e
      Rails.logger.error("[NsfwDetector] Pre-filter failed: #{e.message}")
      nil
    end

    # --- Stage 2: FocalNet confirmation ---

    def confirm_model
      @confirm_model ||= OnnxRuntime::Model.new(CONFIRM_PATH.to_s)
    end

    # Returns { safe: Float, questionable: Float, unsafe: Float } or nil
    def run_confirmation(image_path)
      input = preprocess(image_path, CONFIRM_SIZE, :imagenet)
      return nil unless input

      output = confirm_model.predict({ "pixel_values" => input })
      logits = output["logits"].first
      probs = softmax(logits)
      # FocalNet labels: 0=SAFE, 1=QUESTIONABLE, 2=UNSAFE
      { safe: probs[0].to_f, questionable: probs[1].to_f, unsafe: probs[2].to_f }
    rescue => e
      Rails.logger.error("[NsfwDetector] Confirmation failed: #{e.message}")
      nil
    end

    # --- Preprocessing ---

    def preprocess(image_path, target_size, normalization)
      rgb_data = resize_to_raw_rgb(image_path, target_size)
      return nil unless rgb_data

      pixels = rgb_data.unpack("C*")
      channels = Array.new(3) { Array.new(target_size) { Array.new(target_size, 0.0) } }

      pixels.each_slice(3).with_index do |rgb, idx|
        y = idx / target_size
        x = idx % target_size
        3.times do |c|
          val = rgb[c] / 255.0
          channels[c][y][x] = case normalization
          when :vit     then (val - 0.5) / 0.5
          when :imagenet then (val - IMAGENET_MEAN[c]) / IMAGENET_STD[c]
          end
        end
      end

      [ channels ]
    rescue => e
      Rails.logger.error("[NsfwDetector] Preprocessing failed: #{e.message}")
      nil
    end

    def resize_to_raw_rgb(image_path, target_size)
      resize_with_vips(image_path, target_size)
    rescue LoadError, NameError
      resize_with_imagemagick(image_path, target_size)
    end

    def resize_with_vips(image_path, target_size)
      require "vips"
      image = Vips::Image.new_from_file(image_path, access: :sequential)
      scale = [ target_size.to_f / image.width, target_size.to_f / image.height ].max
      image = image.resize(scale)
      image = image.crop(
        (image.width - target_size) / 2, (image.height - target_size) / 2,
        target_size, target_size
      )
      image = image.colourspace(:srgb) if image.bands == 1
      image = image.flatten if image.bands == 4
      image.write_to_memory
    end

    def resize_with_imagemagick(image_path, target_size)
      tmp = Tempfile.new([ "nsfw_rgb", ".rgb" ])
      success = system(
        "convert", image_path,
        "-resize", "#{target_size}x#{target_size}^",
        "-gravity", "center", "-extent", "#{target_size}x#{target_size}",
        "-alpha", "off", "-depth", "8",
        "RGB:#{tmp.path}"
      )
      return nil unless success
      data = File.binread(tmp.path)
      return nil if data.bytesize != target_size * target_size * 3
      data
    ensure
      tmp&.unlink
    end

    # --- Frame extraction ---

    def extract_video_frames(video_path)
      duration = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{Shellwords.escape(video_path)} 2>/dev/null`.strip.to_f
      return extract_frame_at(video_path, [ duration * 0.5, 0.5 ].max) if duration <= 2

      [ 0.2, 0.4, 0.6, 0.8 ].filter_map do |pct|
        extract_frame_at(video_path, duration * pct).first
      end
    rescue => e
      Rails.logger.warn("[NsfwDetector] Video frame extraction failed: #{e.message}")
      []
    end

    def extract_gif_frames(gif_path)
      total = `identify -format "%n\\n" #{Shellwords.escape(gif_path)} 2>/dev/null`.lines.first.to_s.strip.to_i
      return [ gif_path ] if total <= 1

      count = [ total, 4 ].min
      indices = count.times.map { |i| (total * (i + 1) / (count + 1)).clamp(0, total - 1) }.uniq

      indices.filter_map do |idx|
        tmp = Tempfile.new([ "nsfw_gif_#{idx}", ".png" ])
        success = system("convert", "#{gif_path}[#{idx}]", tmp.path, out: File::NULL, err: File::NULL)
        success && File.size(tmp.path) > 0 ? tmp.path : nil
      end
    rescue => e
      Rails.logger.warn("[NsfwDetector] GIF frame extraction failed: #{e.message}")
      [ gif_path ]
    end

    def extract_frame_at(video_path, timestamp)
      tmp = Tempfile.new([ "nsfw_frame", ".png" ])
      success = system(
        "ffmpeg", "-ss", timestamp.round(2).to_s,
        "-i", video_path, "-vframes", "1", "-f", "image2", "-y", tmp.path,
        out: File::NULL, err: File::NULL
      )
      success && File.size(tmp.path) > 0 ? [ tmp.path ] : []
    end

    def ffmpeg_available?
      @ffmpeg_available = system("which", "ffmpeg", out: File::NULL, err: File::NULL) if @ffmpeg_available.nil?
      @ffmpeg_available
    end

    def softmax(logits)
      max = logits.max
      exps = logits.map { |l| Math.exp(l - max) }
      sum = exps.sum
      exps.map { |e| e / sum }
    end
  end
end
