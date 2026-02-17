module FileTypeValidatable
  extend ActiveSupport::Concern

  ALLOWED_CONTENT_TYPES = %w[
    image/jpeg
    image/png
    image/gif
    image/webp
    image/apng
    image/svg+xml
    video/mp4
    video/webm
    video/quicktime
    audio/mpeg
    audio/ogg
    audio/wav
    audio/webm
    audio/mp4
    application/pdf
    text/plain
  ].freeze

  private

  def validate_file_types
    files = params.dig(:message, :files)
    return if files.blank?

    disallowed = files.reject(&:blank?).select { |f| ALLOWED_CONTENT_TYPES.exclude?(f.content_type) }
    return if disallowed.empty?

    types = disallowed.map { |f| "#{f.original_filename} (#{f.content_type})" }.join(", ")
    render json: { error: "File type not allowed: #{types}" }, status: :unprocessable_entity
  end
end
