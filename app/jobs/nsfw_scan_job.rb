class NsfwScanJob < ApplicationJob
  queue_as :default

  # Scans an ActiveStorage attachment for NSFW content and flags the record.
  #
  # Usage:
  #   NsfwScanJob.perform_later("User", user.id, "avatar")
  #   NsfwScanJob.perform_later("Server", server.id, "icon")
  #
  def perform(model_class, record_id, attachment_name)
    return unless NsfwDetector.available?

    record = model_class.constantize.find_by(id: record_id)
    return unless record

    attachment = record.public_send(attachment_name)
    return unless attachment.attached?
    return unless attachment.content_type&.start_with?("image/")

    is_nsfw = Tempfile.create(["nsfw_scan", File.extname(attachment.filename.to_s)]) do |tmp|
      tmp.binmode
      tmp.write(attachment.download)
      tmp.rewind
      NsfwDetector.explicit?(tmp.path, threshold: 0.7)
    end

    flag_column = "#{attachment_name}_nsfw"
    record.update_column(flag_column, is_nsfw) if record.has_attribute?(flag_column)
  rescue => e
    Rails.logger.error("[NsfwScanJob] Failed for #{model_class}##{record_id}.#{attachment_name}: #{e.message}")
  end
end
