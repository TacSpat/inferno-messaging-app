module Admin
  class BaseController < ApplicationController
    before_action :authenticate_user!
    before_action :require_instance_admin!

    private

    def require_instance_admin!
      unless current_user.instance_admin?
        redirect_to root_path, alert: "You don't have access to this area."
      end
    end
  end
end
