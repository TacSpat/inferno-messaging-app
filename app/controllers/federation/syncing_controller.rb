class Federation::SyncingController < ApplicationController
  before_action :authenticate_user!
  layout "syncing"

  def show
    unless current_user.remote?
      redirect_to root_path
      return
    end

    @redirect_to = params[:redirect_to].presence || root_path
    @home_instance = current_user.home_instance_domain
  end
end
