class Users::SessionsController < Devise::SessionsController
  before_action :redirect_if_authenticated, only: [ :new, :create ]
  before_action :redirect_remote_to_nostr_auth, only: [ :new ]
  before_action :set_no_cache, only: [ :new ]

  def create
    session[:pending_invite_code] = params[:invite] if params[:invite].present?
    super
  end

  protected

  def after_sign_in_path_for(resource)
    if session[:pending_invite_code].present?
      invite = Invite.find_by(code: session.delete(:pending_invite_code))
      if invite&.usable?
        server = invite.server
        unless resource.servers.include?(server)
          invite.increment_uses!
          server.server_memberships.create!(user: resource)
        end
        return server_channel_path(server, server.channels.ordered.first)
      end
    end
    super
  end

  private

  def redirect_if_authenticated
    redirect_to authenticated_root_path if user_signed_in?
  end

  # When a user from another instance lands on sign_in (e.g. via direct link or
  # bookmark), redirect them through Nostr auth instead of showing the login form.
  def redirect_remote_to_nostr_auth
    return if user_signed_in?

    referrer_host = begin
      URI.parse(request.referrer.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    from_another_instance = referrer_host.present? && referrer_host != request.host

    # Also check if Devise stored a location the user was trying to reach
    intended = stored_location_for(:user)

    if from_another_instance && referrer_host.present?
      home_instance = referrer_host
      referrer_uri = URI.parse(request.referrer.to_s)
      referrer_port = referrer_uri.port
      default_port = referrer_uri.scheme == "https" ? 443 : 80
      home_instance += ":#{referrer_port}" if referrer_port && referrer_port != default_port

      redirect_to nostr_auth_path(home_instance: home_instance, redirect_to: intended)
    elsif intended
      # Re-store it since stored_location_for consumes it
      store_location_for(:user, intended)
    end
  end

  def set_no_cache
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
  end
end
