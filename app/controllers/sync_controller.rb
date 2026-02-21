class SyncController < ApplicationController
  before_action :authenticate_user!

  def refresh
    NostrSyncJob.perform_later(current_user.id, since_hours: params[:hours]&.to_i || 168)
    head :accepted
  end
end
