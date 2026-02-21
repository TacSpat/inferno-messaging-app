class ApplicationController < ActionController::Base
  before_action :configure_permitted_parameters, if: :devise_controller?

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:username, :display_name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:username, :display_name, :bio, :status, :status_emoji, :avatar, :banner])
  end
end
