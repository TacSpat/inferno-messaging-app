class ApplicationController < ActionController::Base
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :sync_on_search_referral

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [ :username, :display_name ])
    devise_parameter_sanitizer.permit(:account_update, keys: [ :username, :display_name, :bio, :status, :status_emoji, :avatar, :banner ])
  end

  private

  SEARCH_ENGINES = /\b(google|bing|duckduckgo|yahoo|yandex|baidu|ecosia|brave|startpage)\./i

  def sync_on_search_referral
    return unless user_signed_in?
    return if session[:synced_from_search]

    referrer = request.referer
    return unless referrer&.match?(SEARCH_ENGINES)

    session[:synced_from_search] = true
    NostrSyncJob.perform_later(current_user.id) if current_user.nostr_public_key.present?
  end
end
