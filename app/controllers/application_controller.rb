class ApplicationController < ActionController::Base
  include Pundit::Authorization

  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :set_paper_trail_whodunnit

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:username, :display_name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:username, :display_name, :bio, :status, :status_emoji, :avatar, :banner])
  end

  # PaperTrail uses this to set whodunnit
  def user_for_paper_trail
    current_user&.id&.to_s
  end
end
