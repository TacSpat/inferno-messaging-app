class Users::RegistrationsController < Devise::RegistrationsController
  before_action :redirect_if_authenticated, only: [:new, :create]
  before_action :set_no_cache, only: [:new]

  protected

  def after_inactive_sign_up_path_for(resource)
    users_check_email_path
  end

  private

  def redirect_if_authenticated
    redirect_to authenticated_root_path if user_signed_in?
  end

  def set_no_cache
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
  end
end
