class ModerationReportsController < ApplicationController
  before_action :authenticate_user!

  def create
    pubkey = params[:reported_pubkey]
    if pubkey.blank?
      redirect_back fallback_location: root_path, alert: "Missing reported user."
      return
    end

    report = ModerationReport.new(
      reporter: current_user,
      reported_pubkey: pubkey,
      reported_event_id: params[:reported_event_id],
      report_type: params[:report_type],
      reason: params[:reason]
    )

    if report.save
      redirect_back fallback_location: root_path, notice: "Report submitted. Admins will review it."
    else
      redirect_back fallback_location: root_path, alert: report.errors.full_messages.join(", ")
    end
  end
end
