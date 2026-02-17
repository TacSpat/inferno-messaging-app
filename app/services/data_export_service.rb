class DataExportService
  def self.call(export)
    export.process!

    export_dir = Rails.root.join("tmp", "exports")
    FileUtils.mkdir_p(export_dir)
    zip_path = export_dir.join("export_#{export.id}_#{Time.current.to_i}.zip")

    # Stub: creates an empty ZIP as a placeholder.
    # Full implementation will collect user messages, profile data, etc.
    File.write(zip_path, "")

    export.complete!(zip_path.to_s)
  end
end
