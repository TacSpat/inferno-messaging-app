class InvitesController < ApplicationController
  before_action :set_invite

  def show
    if @invite_state == :not_found
      respond_to do |format|
        format.json { render json: { error: "Invite not found." }, status: :not_found }
        format.html { redirect_to root_path, alert: "Invite not found." }
      end
      return
    end

    if @relay_invite
      # Server not local — show preview from relay data
      @server_name = @relay_invite[:server_name]
      @icon_url = @relay_invite[:icon_url]
      @member_count = @relay_invite[:member_count] || 0
      @online_count = 0
      @nostr_group_id = params[:nostr_group_id]
    else
      @server = @invite.server
      @member_count = @server.total_member_count
      @online_count = @server.members.where(online_state: :online).count
      @nostr_group_id = @server.nostr_group_id
    end

    respond_to do |format|
      format.html do
        unless @relay_invite
          @already_member = user_signed_in? && current_user.servers.include?(@server)
          @ban = user_signed_in? && @server.bans.find_by(user: current_user)
        end
      end
      format.json do
        if @relay_invite
          render json: {
            server_name: @server_name,
            icon_url: @icon_url,
            member_count: @member_count,
            online_count: 0,
            invite_code: params[:code],
            nostr_group_id: @nostr_group_id,
            state: @invite_state
          }
        else
          render json: {
            server_name: @server.name,
            description: @server.description,
            icon_url: @server.icon.attached? ? rails_blob_url(@server.icon) : nil,
            member_count: @member_count,
            online_count: @online_count,
            invite_code: @invite.code,
            nostr_group_id: @nostr_group_id,
            naddr: @invite.to_naddr,
            state: @invite_state
          }
        end
      end
    end
  end

  def accept
    if @invite_state != :valid
      if params[:nostr_group_id].present?
        redirect_to nostr_invite_path(params[:nostr_group_id], params[:code]), alert: invite_state_message
      else
        redirect_to invite_path(params[:code]), alert: invite_state_message
      end
      return
    end

    # If server not local but we have a nostr_group_id, redirect to the Nostr join flow
    if @relay_invite && params[:nostr_group_id].present?
      redirect_to join_nostr_server_path(params[:nostr_group_id])
      return
    end

    @server = @invite.server

    unless user_signed_in?
      session[:pending_invite_code] = @invite.code
      redirect_to new_user_session_path, notice: "Sign in to join #{@server.name}!"
      return
    end

    ban = @server.bans.find_by(user: current_user)
    if ban
      invite_show_path = params[:nostr_group_id].present? ? nostr_invite_path(params[:nostr_group_id], @invite.code) : invite_path(@invite.code)
      redirect_to invite_show_path, alert: "You are banned from this server."
      return
    end

    if current_user.servers.include?(@server)
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
    else
      # Bootstrap server state from Nostr relays if this server has a nostr_group_id
      if @server.nostr_group_id.present?
        NostrServerSyncService.new(@server.nostr_group_id, joining_user: current_user).sync_all
      end

      @invite.increment_uses!
      @server.server_memberships.create!(user: current_user)

      # Re-publish invite with updated uses count
      NostrServerPublishJob.perform_later(current_user.id, @server.id, "invite", invite_code: @invite.code)

      # Publish self-join member event to Nostr
      if current_user.nostr_public_key.present?
        NostrServerPublishJob.perform_later(current_user.id, @server.id, "member", pubkey: current_user.nostr_public_key)
      end

      redirect_to server_channel_path(@server, @server.channels.ordered.first), notice: "Welcome to #{@server.name}!"
    end
  end

  private

  def set_invite
    @invite = Invite.find_by(code: params[:code])
    @nostr_group_id = params[:nostr_group_id]

    if @invite
      # Local invite found — determine state
      @invite_state = if !@invite.active?
        :revoked
      elsif @invite.expired?
        :expired
      elsif @invite.maxed_out?
        :maxed_out
      else
        :valid
      end
      return
    end

    # No local invite — try relay lookup if nostr_group_id present
    if @nostr_group_id.present?
      # Try to find the server locally and sync invites from relay
      server = Server.find_by(nostr_group_id: @nostr_group_id)
      if server
        NostrServerSyncService.new(@nostr_group_id).sync_invites
        @invite = Invite.find_by(code: params[:code])
        if @invite
          @invite_state = if !@invite.active?
            :revoked
          elsif @invite.expired?
            :expired
          elsif @invite.maxed_out?
            :maxed_out
          else
            :valid
          end
          return
        end
      end

      # Server not local either — fetch invite metadata from relay
      relay_data = fetch_invite_from_relay(@nostr_group_id, params[:code])
      if relay_data
        @invite_state = relay_data[:state]
        @relay_invite = relay_data
        return
      end
    end

    @invite_state = :not_found
  end

  def fetch_invite_from_relay(nostr_group_id, code)
    d_tag = "inferno-invite-#{nostr_group_id}-#{code}"
    events = RelayService.fetch_from_all({
      kinds: [ RelaySubscriptionManager::KIND_SERVER_INVITE ],
      "#d" => [ d_tag ]
    })
    return nil if events.empty?

    event = events.max_by { |e| e["created_at"].to_i }
    tags = event["tags"] || []
    tag_val = ->(key) { tags.find { |t| t[0] == key }&.dig(1) }

    # Determine state from tags
    revoked = tag_val.call("revoked") == "true"
    expires_at_str = tag_val.call("expires_at")
    max_uses = tag_val.call("max_uses")&.to_i
    uses_count = tag_val.call("uses_count")&.to_i || 0

    state = if revoked
      :revoked
    elsif expires_at_str.present? && Time.parse(expires_at_str) <= Time.current
      :expired
    elsif max_uses.present? && max_uses > 0 && uses_count >= max_uses
      :maxed_out
    else
      :valid
    end

    # Fetch server metadata preview
    server_info = NostrServerSyncService.fetch_metadata_preview(nostr_group_id)

    {
      state: state,
      server_name: server_info&.dig(:name) || "Unknown Server",
      icon_url: server_info&.dig(:picture_url),
      member_count: server_info&.dig(:member_count) || 0
    }
  rescue => e
    Rails.logger.warn("[InvitesController] fetch_invite_from_relay failed: #{e.message}")
    nil
  end

  def invite_state_message
    case @invite_state
    when :expired then "This invite has expired."
    when :revoked then "This invite is no longer valid."
    when :maxed_out then "This invite has reached its maximum uses."
    else "Invalid invite link."
    end
  end
end
