module Admin
  class ModerationReportsController < BaseController
    def index
      @reports = ModerationReport.includes(:reporter, :reviewed_by)
      @reports = case params[:filter]
      when "resolved" then @reports.resolved
      when "all" then @reports
      else @reports.open_reports
      end
      @reports = @reports.order(created_at: :desc)
      @open_count = ModerationReport.open_reports.count
    end

    def show
      @report = ModerationReport.find(params[:id])
      @remote_user = @report.reported_remote_user
      @related_reports = ModerationReport.by_pubkey(@report.reported_pubkey)
                                          .where.not(id: @report.id)
                                          .order(created_at: :desc)
                                          .limit(10)
    end

    def review
      @report = ModerationReport.find(params[:id])
      new_status = params[:status]

      unless ModerationReport::STATUSES.include?(new_status)
        redirect_to admin_moderation_report_path(@report), alert: "Invalid status."
        return
      end

      @report.review!(current_user, new_status: new_status)

      # Optionally publish NIP-56 report to relays
      if params[:publish_to_relays] == "1" && new_status == "actioned"
        NostrReportPublishJob.perform_later(@report.id)
      end

      redirect_to admin_moderation_reports_path, notice: "Report marked as #{new_status}."
    end
  end
end
