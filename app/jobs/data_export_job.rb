class DataExportJob < ApplicationJob
  queue_as :default

  def perform(export_id)
    export = DataExport.find(export_id)
    DataExportService.call(export)
  rescue StandardError => e
    export&.fail!
    Rails.logger.error("[DataExportJob] Export ##{export_id} failed: #{e.message}")
    raise
  end
end
