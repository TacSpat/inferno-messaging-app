class Users::SessionsController < Devise::SessionsController
  before_action :redirect_to_setup, only: [ :new ]
  before_action :redirect_if_authenticated, only: [ :new, :create ]

  def create
    session[:pending_invite_code] = params[:invite] if params[:invite].present?
    super
  end

  protected

  def after_sign_in_path_for(resource)
    # Sync messages from relays (catches up from other devices)
    NostrSyncJob.perform_later(resource.id) if resource.nostr_public_key.present?

    if session[:pending_invite_code].present?
      invite = Invite.find_by(code: session.delete(:pending_invite_code))
      if invite&.usable?
        server = invite.server
        unless resource.servers.include?(server)
          invite.increment_uses!
          server.server_memberships.create!(user: resource)
          NostrServerPublishJob.perform_later(resource.id, server.id, "invite", invite_code: invite.code)
        end
        return server_channel_path(server, server.channels.ordered.first)
      end
    end
    super
  end

  private

  def redirect_to_setup
    redirect_to setup_path if User.none?
  end

  def redirect_if_authenticated
    redirect_to authenticated_root_path if user_signed_in?
  end
end
