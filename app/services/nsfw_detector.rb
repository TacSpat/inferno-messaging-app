# Classifies images as SFW/NSFW using a local ONNX model.
# Runs entirely on-device — no cloud API, works offline.
#
# Place the model at lib/models/nsfw_classifier.onnx
# Compatible with the open-source Yahoo/open_nsfw model (converted to ONNX).
#
# Input: 224x224 RGB image normalized to [0,1]
# Output: [sfw_probability, nsfw_probability]
#
class NsfwDetector
  MODEL_PATH = Rails.root.join("lib/models/nsfw_classifier.onnx")
  INPUT_SIZE = 224

  class << self
    def available?
      defined?(OnnxRuntime) && File.exist?(MODEL_PATH)
    end

    # Returns { safe: Float, explicit: Float }
    def classify(image_path)
      return { safe: 1.0, explicit: 0.0 } unless available?

      input = preprocess(image_path)
      return { safe: 1.0, explicit: 0.0 } unless input

      output = model.predict({ "input:0" => input })
      probs = output["outputs"]&.first || output.values.first.first

      # Yahoo open_nsfw outputs [sfw, nsfw]
      { safe: probs[0].to_f, explicit: probs[1].to_f }
    rescue => e
      Rails.logger.error("[NsfwDetector] Classification failed: #{e.message}")
      { safe: 1.0, explicit: 0.0 }
    end

    # Quick boolean check
    def explicit?(image_path, threshold: 0.7)
      return false unless available?
      result = classify(image_path)
      result[:explicit] >= threshold
    end

    # Classify all image attachments on a message.
    # Returns true if ANY image is flagged as explicit.
    def any_explicit?(message, threshold: 0.7)
      return false unless available?
      return false unless message.files.attached?

      message.files.select { |f| f.content_type&.start_with?("image/") }.any? do |file|
        Tempfile.create(["nsfw_check", File.extname(file.filename.to_s)]) do |tmp|
          tmp.binmode
          tmp.write(file.download)
          tmp.rewind
          explicit?(tmp.path, threshold: threshold)
        end
      end
    rescue => e
      Rails.logger.error("[NsfwDetector] Batch check failed: #{e.message}")
      false
    end

    private

    def model
      @model ||= OnnxRuntime::Model.new(MODEL_PATH.to_s)
    end

    # Preprocess image to 224x224 normalized float array.
    # Uses Vips for fast resizing (already a dependency via image_processing).
    def preprocess(image_path)
      image = Vips::Image.new_from_file(image_path, access: :sequential)

      # Resize to INPUT_SIZE x INPUT_SIZE
      scale = [INPUT_SIZE.to_f / image.width, INPUT_SIZE.to_f / image.height].max
      image = image.resize(scale)
      image = image.crop(
        (image.width - INPUT_SIZE) / 2,
        (image.height - INPUT_SIZE) / 2,
        INPUT_SIZE,
        INPUT_SIZE
      )

      # Ensure 3 channels (RGB)
      image = image.colourspace(:srgb) if image.bands == 1
      image = image.flatten if image.bands == 4  # remove alpha

      # Convert to float array normalized to [0, 1]
      # Shape: [1, INPUT_SIZE, INPUT_SIZE, 3] (NHWC)
      pixels = image.to_a.map do |row|
        row.map do |pixel|
          pixel.map { |v| v / 255.0 }
        end
      end

      [pixels]
    rescue => e
      Rails.logger.error("[NsfwDetector] Preprocessing failed: #{e.message}")
      nil
    end
  end
end
