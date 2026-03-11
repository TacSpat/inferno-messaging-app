class ServersController < ApplicationController
  include MessageSearchable

  before_action :authenticate_user!
  before_action :set_server, only: [ :show, :edit, :update, :destroy, :join, :leave, :search, :onboarding, :complete_onboarding ]
  before_action :set_no_cache, only: [ :new ]

  def show
    first_channel = @server.channels.ordered.first
    if first_channel
      redirect_to server_channel_path(@server, first_channel)
    else
      redirect_to root_path
    end
  end

  def new
    @server = Server.new
  end

  def create
    @server = Server.new(server_params)
    @server.owner = current_user
    if @server.save
      # Apply server type template if specified (replaces default channels/roles)
      server_type = params.dig(:server, :server_type).presence
      if server_type && server_type != "community"
        @server.apply_server_template!(server_type)
      end

      publish_server_state(:metadata)
      publish_server_state(:structure)
      publish_server_state(:roles)
      publish_server_state(:member, pubkey: current_user.nostr_public_key)
      NsfwScanJob.perform_later("Server", @server.id, "icon") if server_params[:icon].present?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @server.update(server_params)
      publish_server_state(:metadata)
      NsfwScanJob.perform_later("Server", @server.id, "icon") if server_params[:icon].present?
      NsfwScanJob.perform_later("Server", @server.id, "banner") if server_params[:banner].present?
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    # Publish deletion synchronously — the server record must exist when the job reads it
    if current_user.nostr_public_key.present?
      NostrServerPublishJob.perform_now(current_user.id, @server.id, "metadata", deleted: true)
    end
    ServerChannel.broadcast_to(@server, { type: "server_deleted" })
    @server.destroy
    redirect_to root_path, notice: "Server deleted.", status: :see_other
  end

  def join
    unless current_user.servers.include?(@server)
      # Age-restricted servers require explicit confirmation
      if @server.age_restricted? && params[:age_confirmed] != "true"
        redirect_to server_channel_path(@server, @server.channels.ordered.first),
          alert: "You must confirm you are 18 or older to join this server."
        return
      end

      @server.server_memberships.create!(user: current_user, joined_at: Time.current)
      publish_server_state(:member, pubkey: current_user.nostr_public_key)
    end
    redirect_to server_channel_path(@server, @server.channels.ordered.first)
  end

  def search
    channels = @server.channels.accessible_to(current_user)

    # Backfill from relays for channels with time filters
    channels.each { |ch| backfill_channel_history!(ch) }

    messages = Message.where(channel: channels).where.not(system_message: true)
    messages = apply_search_filters(messages)

    per_page = 25
    page = [ params[:page].to_i, 1 ].max
    total = messages.count
    @results = messages.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page)

    ActiveRecord::Associations::Preloader.new(
      records: @results,
      associations: [ :user, :channel, { files_attachments: :blob }, :reactions ]
    ).call

    render partial: "messages/search_results", locals: { results: @results, server: @server, page: page, total: total, has_more: (page * per_page) < total }
  end

  def onboarding
    @membership = @server.server_memberships.find_by!(user: current_user)

    unless @server.onboarding_enabled? && !@membership.onboarding_completed?
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
      return
    end

    @self_assignable_roles = @server.roles.where(self_assignable: true).ordered
    @default_channels = @server.channels.text.ordered
    render layout: "minimal"
  end

  def complete_onboarding
    @membership = @server.server_memberships.find_by!(user: current_user)

    # Assign selected roles
    role_ids = Array(params[:role_ids]).select(&:present?)
    if role_ids.any?
      assignable = @server.roles.where(self_assignable: true, public_id: role_ids)
      assignable.each do |role|
        @membership.roles << role unless @membership.roles.include?(role)
      end
    end

    @membership.update!(onboarding_completed: true)
    redirect_to server_channel_path(@server, @server.channels.ordered.first), notice: "Welcome to #{@server.name}!"
  end

  def leave
    membership = @server.server_memberships.find_by(user: current_user)
    if membership && @server.owner != current_user
      membership.destroy
      publish_server_state(:member, pubkey: current_user.nostr_public_key, removed: true)
      redirect_to root_path, notice: "Left server.", status: :see_other
    else
      redirect_back fallback_location: root_path, alert: "Can't leave a server you own."
    end
  end

  # POST /servers/resolve_preview — resolves an invite link, code, or server ID to preview data
  def resolve_preview
    input = params[:input].to_s.strip
    return render(json: { error: "No input" }, status: :unprocessable_entity) if input.blank?

    # Try as nostr:naddr or bare naddr1 URI
    if input.match?(/\A(?:nostr:)?naddr1/i)
      naddr_input = input.start_with?("nostr:") ? input : "nostr:#{input}"
      decoded = Invite.decode_naddr(naddr_input)
      if decoded
        return render_invite_preview(decoded[:code], decoded[:nostr_group_id])
      end
    end

    # Try as invite URL: .../inferno/invite/GID/CODE
    if (m = input.match(%r{inferno/invite/([^/]+)/([^/\s]+)}))
      return render_invite_preview(m[2], m[1])
    end

    # Try as invite URL without GID: .../inferno/invite/CODE
    if (m = input.match(%r{inferno/invite/([^/\s]+)}))
      return render_invite_preview(m[1], nil)
    end

    # Try as server URL: .../inferno/server/GID
    if (m = input.match(%r{inferno/server/([^/\s]+)}))
      return render_server_preview(m[1])
    end

    # Try as local invite code (any alphanumeric string)
    invite = Invite.find_by(code: input)
    if invite
      return render_invite_preview(invite.code, invite.server.nostr_group_id)
    end

    # Try as nostr group ID (hex, or prefixed with "inferno-")
    if input.match?(/\A[a-f0-9]{8,}\z/i) || input.start_with?("inferno-")
      return render_server_preview(input)
    end

    # Last resort: search relays for this as an invite code
    if input.match?(/\A[a-zA-Z0-9]+\z/)
      render_relay_invite_search(input)
      return
    end

    render json: { error: "Could not resolve input" }, status: :not_found
  end

  def reorder_servers
    items = params.require(:items)
    memberships = current_user.server_memberships.includes(:server).index_by { |m| m.server.public_id }
    folders = current_user.server_folders.index_by(&:public_id)

    ActiveRecord::Base.transaction do
      items.each do |entry|
        pos = entry[:position].to_i
        if entry[:type] == "folder"
          folder = folders[entry[:id]]
          next unless folder
          folder.update_column(:position, pos)

          (entry[:servers] || []).each do |server_entry|
            membership = memberships[server_entry[:id]]
            next unless membership
            membership.update_columns(position: server_entry[:position].to_i, server_folder_id: folder.id)
          end
        else
          membership = memberships[entry[:id]]
          next unless membership
          membership.update_columns(position: pos, server_folder_id: nil)
        end
      end
    end

    head :ok
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:id])
  end

  def server_params
    params.require(:server).permit(:name, :description, :icon, :banner, :discoverable, :server_type)
  end

  def set_no_cache
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
  end

  def render_invite_preview(code, nostr_group_id)
    # Local lookup
    invite = Invite.find_by(code: code)
    if invite
      server = invite.server
      state = if !invite.active? then "revoked"
      elsif invite.expired? then "expired"
      elsif invite.maxed_out? then "maxed_out"
      else "valid"
      end
      return render json: {
        name: server.name,
        description: server.description,
        icon_url: server.icon.attached? ? rails_blob_url(server.icon) : nil,
        member_count: server.total_member_count,
        online_count: server.members.where(online_state: :online).count,
        join_url: nostr_group_id ? "/inferno/invite/#{nostr_group_id}/#{code}" : "/inferno/invite/#{code}",
        join_method: "invite",
        state: state,
        age_restricted: server.age_restricted?
      }
    end

    # Relay lookup
    if nostr_group_id.present?
      relay_data = fetch_invite_from_relay(nostr_group_id, code)
      if relay_data
        return render json: {
          name: relay_data[:server_name],
          icon_url: relay_data[:icon_url],
          member_count: relay_data[:member_count] || 0,
          online_count: 0,
          join_url: "/inferno/invite/#{nostr_group_id}/#{code}",
          join_method: "invite",
          state: relay_data[:state].to_s
        }
      end
    end

    render json: { error: "Invite not found" }, status: :not_found
  end

  def render_server_preview(nostr_group_id)
    local = Server.find_by(nostr_group_id: nostr_group_id)
    if local
      return render json: {
        name: local.name,
        description: local.description,
        icon_url: local.icon.attached? ? rails_blob_url(local.icon) : nil,
        member_count: local.total_member_count,
        online_count: local.members.where(online_state: :online).count,
        join_url: "/inferno/server/#{nostr_group_id}/join",
        join_method: "server",
        age_restricted: local.age_restricted?
      }
    end

    # Fetch from relays
    info = NostrServerSyncService.fetch_metadata_preview(nostr_group_id)
    if info && info[:name].present?
      return render json: {
        name: info[:name],
        description: info[:about],
        icon_url: info[:picture_url],
        member_count: info[:member_count] || 0,
        online_count: 0,
        join_url: "/inferno/server/#{nostr_group_id}/join",
        join_method: "server"
      }
    end

    render json: { error: "Server not found" }, status: :not_found
  end

  def render_relay_invite_search(code)
    # Search all known servers for this invite code via relay
    Server.where.not(nostr_group_id: nil).find_each do |server|
      relay_data = fetch_invite_from_relay(server.nostr_group_id, code)
      next unless relay_data && relay_data[:state] == :valid

      return render json: {
        name: relay_data[:server_name],
        icon_url: relay_data[:icon_url],
        member_count: relay_data[:member_count] || 0,
        online_count: 0,
        join_url: "/inferno/invite/#{server.nostr_group_id}/#{code}",
        join_method: "invite",
        state: "valid"
      }
    end

    render json: { error: "Invite not found on any connected relay" }, status: :not_found
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

    revoked = tag_val.call("revoked") == "true"
    expires_at_str = tag_val.call("expires_at")
    max_uses = tag_val.call("max_uses")&.to_i
    uses_count = tag_val.call("uses_count")&.to_i || 0

    state = if revoked then :revoked
    elsif expires_at_str.present? && Time.parse(expires_at_str) <= Time.current then :expired
    elsif max_uses.present? && max_uses > 0 && uses_count >= max_uses then :maxed_out
    else :valid
    end

    server_info = NostrServerSyncService.fetch_metadata_preview(nostr_group_id)
    {
      state: state,
      server_name: server_info&.dig(:name) || "Unknown Server",
      icon_url: server_info&.dig(:picture_url),
      member_count: server_info&.dig(:member_count) || 0
    }
  rescue => e
    Rails.logger.warn("[ServersController] fetch_invite_from_relay failed: #{e.message}")
    nil
  end

  def publish_server_state(event_type, **options)
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, event_type.to_s, **options)
  end
end
