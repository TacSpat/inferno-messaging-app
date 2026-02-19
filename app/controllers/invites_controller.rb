class InvitesController < ApplicationController
  before_action :set_invite

  def show
    @server = @invite.server
    @member_count = @server.members.count
    @online_count = @server.members.where(online_state: :online).count
    @instance_domain = Rails.application.config.x.instance_domain

    respond_to do |format|
      format.html do
        @already_member = user_signed_in? && current_user.servers.include?(@server)

        # Auto-detect home instance for federation auth (only when not logged in)
        unless user_signed_in? || @already_member
          if params[:from].present?
            # Explicit ?from= param — auto-redirect through NIP-42
            session[:pending_invite_code] = @invite.code
            redirect_to nostr_auth_path(home_instance: params[:from])
            return
          end

          # Fall back to Referer header sniffing
          @detected_home_instance = detect_home_instance_from_referer
        end
      end
      format.json do
        render json: {
          server_name: @server.name,
          description: @server.description,
          icon_url: @server.icon.attached? ? rails_blob_url(@server.icon) : nil,
          banner_url: @server.respond_to?(:banner) && @server.banner.attached? ? rails_blob_url(@server.banner) : nil,
          member_count: @member_count,
          online_count: @online_count,
          instance_domain: @instance_domain,
          invite_code: @invite.code
        }
      end
    end
  end

  def accept
    @server = @invite.server

    # Not logged in — store invite and redirect
    unless user_signed_in?
      session[:pending_invite_code] = @invite.code
      if params[:home_instance].present?
        redirect_to nostr_auth_path(home_instance: params[:home_instance])
      else
        redirect_to new_user_registration_path, notice: "Create an account to join #{@server.name}!"
      end
      return
    end

    # Block remote users from joining if remote joins are locked down
    if current_user.remote? && InstanceConfig.current.remote_joins_blocked?
      redirect_to root_path, alert: "Remote user joins are currently disabled."
      return
    end

    if current_user.servers.include?(@server)
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
    else
      @invite.increment_uses!
      @server.server_memberships.create!(user: current_user)
      redirect_to server_channel_path(@server, @server.channels.ordered.first), notice: "Welcome to #{@server.name}!"
    end
  end

  private

  def set_invite
    @invite = Invite.find_by(code: params[:code])
    unless @invite&.usable?
      respond_to do |format|
        format.json { render json: { error: "Invalid, expired, or maxed-out invite." }, status: :not_found }
        format.html { redirect_to root_path, alert: "Invalid, expired, or reached maximum uses invite link." }
      end
    end
  end

  def detect_home_instance_from_referer
    referer = request.referer
    return nil if referer.blank?

    referer_uri = URI.parse(referer)
    return nil if referer_uri.host.blank?

    # Compare host:port to handle localhost with different ports (dev)
    referer_authority = "#{referer_uri.host}:#{referer_uri.port}"
    local_authority = "#{request.host}:#{request.port}"
    return nil if referer_authority == local_authority

    # Return host:port for localhost (dev), just host for production
    referer_uri.host == "localhost" ? referer_authority : referer_uri.host
  rescue URI::InvalidURIError
    nil
  end
end
