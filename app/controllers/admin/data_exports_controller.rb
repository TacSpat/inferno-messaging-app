module Admin
  class DataExportsController < BaseController
    def index
      @exports = DataExport.includes(:user, :requested_by).order(created_at: :desc)
    end

    def create
      user = User.find(params[:user_id])
      export = DataExport.create!(
        user: user,
        requested_by: current_user,
        export_type: params[:export_type] || "full"
      )

      DataExportJob.perform_later(export.id)
      redirect_to admin_data_exports_path, notice: "Data export queued for #{user.username}."
    end

    def download
      export = DataExport.find(params[:id])

      if export.status != "completed" || export.file_path.blank?
        redirect_to admin_data_exports_path, alert: "Export is not ready for download."
        return
      end

      if export.expired?
        redirect_to admin_data_exports_path, alert: "Export has expired."
        return
      end

      send_file export.file_path, filename: "export_#{export.user_id}_#{export.id}.zip"
    end
  end
end
