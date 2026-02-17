class ApplicationController < ActionController::Base
  include Pundit::Authorization

  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :set_paper_trail_whodunnit
  before_action :set_current_voice_state

  protected

  def set_current_voice_state
    @current_voice_state = current_user&.voice_states&.includes(:channel)&.first
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:username, :display_name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:username, :display_name, :bio, :status, :status_emoji, :avatar, :banner])
  end

  # PaperTrail uses this to set whodunnit
  def user_for_paper_trail
    current_user&.id&.to_s
  end

  # PaperTrail merges this into every new version record
  def info_for_paper_trail
    {
      ip_address: request.remote_ip,
      remote_domain: @paper_trail_remote_domain,
      metadata: @paper_trail_metadata
    }.compact
  end
end
