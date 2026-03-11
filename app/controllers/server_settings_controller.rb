class ServerSettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_current_membership
  before_action :ensure_permission!, except: [ :invites, :create_invite, :destroy_invite, :update_member, :emojis, :stickers, :voice, :opt_in_voice, :opt_out_voice, :timeout_member, :remove_timeout, :member_history, :prune_preview, :prune_members, :batch_kick, :batch_ban, :batch_timeout, :relays, :add_relay, :remove_relay, :verify_member, :unverify_member ]
  before_action :ensure_relay_permission!, only: [ :relays, :add_relay, :remove_relay ]
  before_action :ensure_invite_permission!, only: [ :invites, :create_invite, :destroy_invite ]
  before_action :ensure_emoji_permission!, only: [ :emojis ]
  before_action :ensure_sticker_permission!, only: [ :stickers ]
  layout "server_settings"

  def overview
  end

  def update_overview
    if @server.update(server_params)
      publish_server_state(:metadata)
      redirect_to server_settings_overview_path(@server), notice: "Server updated."
    else
      render :overview, status: :unprocessable_entity
    end
  end

  def roles
    @roles = @server.roles.ordered
  end

  def members
    @all_roles = @server.roles.where("json_extract(permissions, '$.owner') IS NOT TRUE").ordered
    @all_members = build_members_list
  end

  def update_member
    membership = @server.server_memberships.find_by(public_id: params[:id])
    remote_member = @server.remote_members.find_by(public_id: params[:id]) unless membership
    raise ActiveRecord::RecordNotFound unless membership || remote_member

    is_self = membership&.user == current_user

    # Handle nickname update (local members only)
    if params.key?(:nickname) && membership
      unless is_self || @current_membership&.admin? || @current_membership&.has_permission?("manage_roles")
        return respond_to do |format|
          format.json { render json: { error: "Permission denied" }, status: :forbidden }
          format.html { redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission." }
        end
      end
      nickname = params[:nickname].presence
      membership.update!(nickname: nickname)
      broadcast_member_update(membership)
      publish_server_state(:member, pubkey: membership.user.nostr_public_key)
      return respond_to do |format|
        format.json { render json: { success: true, nickname: membership.nickname, display_name: membership.user.display_name_for(@server) } }
        format.html { redirect_to server_settings_members_path(@server), notice: "Nickname updated." }
      end
    end

    # Handle role update — requires admin or manage_roles
    unless @current_membership&.admin? || @current_membership&.has_permission?("manage_roles")
      return respond_to do |format|
        format.json { render json: { error: "Permission denied" }, status: :forbidden }
        format.html { redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission." }
      end
    end

    target = membership || remote_member
    role_ids = Array(params[:role_ids])
    roles = @server.roles.where(public_id: role_ids).reject(&:owner?)

    # Owner role cannot be removed from the server owner
    owner_role = target.roles.find(&:owner?)
    roles << owner_role if owner_role

    target.roles = roles
    pubkey = membership&.user&.nostr_public_key || remote_member&.pubkey
    broadcast_member_update(membership) if membership
    publish_server_state(:member, pubkey: pubkey) if pubkey.present?

    respond_to do |format|
      format.json do
        render json: {
          success: true,
          roles: target.roles.ordered.map { |r| { id: r.public_id, name: r.name, color: r.color, position: r.position } }
        }
      end
      format.html do
        name = membership&.user&.username || remote_member&.username
        redirect_to server_settings_members_path(@server), notice: "Roles updated for #{name}."
      end
    end
  end

  def kick_member
    membership = @server.server_memberships.find_by!(public_id: params[:id])
    return redirect_to server_settings_members_path(@server), alert: "Can't kick the owner." if membership.owner?
    username = membership.user.username
    kicked_pubkey = membership.user.nostr_public_key
    membership.destroy
    publish_server_state(:member, pubkey: kicked_pubkey, removed: true) if kicked_pubkey.present?
    redirect_to server_settings_members_path(@server), notice: "#{username} has been kicked."
  end

  def kick_remote_member
    remote_member = @server.remote_members.find_by!(public_id: params[:id])
    username = remote_member.username
    kicked_pubkey = remote_member.pubkey
    remote_member.destroy
    publish_server_state(:member, pubkey: kicked_pubkey, removed: true) if kicked_pubkey.present?
    redirect_to server_settings_members_path(@server), notice: "#{username} has been kicked."
  end

  def invites
    if @current_membership.has_permission?("manage_invites")
      @invites = @server.invites.active_invites.includes(:creator).order(created_at: :desc)
    else
      @invites = @server.invites.active_invites.where(creator: current_user).order(created_at: :desc)
    end
  end

  def create_invite
    expires_at = case params[:expires_in]
    when "30m" then 30.minutes.from_now
    when "1h"  then 1.hour.from_now
    when "6h"  then 6.hours.from_now
    when "12h" then 12.hours.from_now
    when "1d"  then 1.day.from_now
    when "7d"  then 7.days.from_now
    end

    max_uses = params[:max_uses].presence&.to_i

    invite = @server.invites.create!(creator: current_user, expires_at: expires_at, max_uses: max_uses)
    publish_server_state(:invite, invite_code: invite.code)

    respond_to do |format|
      format.html { redirect_to server_settings_invites_path(@server), notice: "Invite created." }
      format.json { render json: { code: invite.code, nostr_group_id: @server.nostr_group_id, naddr: invite.to_naddr } }
    end
  end

  def destroy_invite
    invite = @server.invites.find(params[:invite_id])
    unless invite.creator == current_user || @current_membership.has_permission?("manage_invites")
      return redirect_to server_settings_invites_path(@server), alert: "You can only revoke your own invites."
    end
    invite.update!(active: false)
    publish_server_state(:invite, invite_code: invite.code, revoked: true)
    redirect_to server_settings_invites_path(@server), notice: "Invite revoked."
  end

  def emojis
    @emojis = @server.server_emojis.includes(:creator, image_attachment: :blob).order(:name)
  end

  def stickers
    @stickers = @server.server_stickers.includes(:creator, image_attachment: :blob).order(:name)
  end

  def audit_log
    admin_kinds = [
      RelaySubscriptionManager::KIND_SERVER_METADATA,
      RelaySubscriptionManager::KIND_SERVER_STRUCTURE,
      RelaySubscriptionManager::KIND_SERVER_ROLES,
      RelaySubscriptionManager::KIND_SERVER_MEMBER,
      RelaySubscriptionManager::KIND_SERVER_EMOJIS,
      RelaySubscriptionManager::KIND_SERVER_STICKERS,
      RelaySubscriptionManager::KIND_SERVER_BAN,
      RelaySubscriptionManager::KIND_SERVER_INVITE
    ]
    @events = NostrEventLog.where(server: @server, kind: admin_kinds)
                           .order(event_created_at: :desc)
                           .limit(50)
  end

  def voice
    @voice_channels = @server.channels.where(channel_type: :voice).ordered
    @providers = @server.server_voice_providers.includes(:user).ordered
    @is_provider = @server.server_voice_providers.exists?(user: current_user)
    @can_volunteer = current_user.livekit_configured? && !@is_provider
  end

  def update_voice
    # Update voice_enabled toggle
    @server.update!(voice_enabled: params[:voice_enabled] == "1") if params.key?(:voice_enabled)

    # Update AFK settings
    if params.key?(:afk_channel_id)
      if params[:afk_channel_id].present?
        afk_ch = @server.channels.voice.find_by(public_id: params[:afk_channel_id])
        @server.afk_channel = afk_ch
      else
        @server.afk_channel = nil
      end
    end
    @server.afk_timeout = params[:afk_timeout].to_i if params.key?(:afk_timeout)
    @server.afk_action = params[:afk_action] if params.key?(:afk_action)
    @server.save! if @server.changed?

    voice_channels = @server.channels.where(channel_type: :voice)

    # Update each voice channel's settings from params
    (params[:channels] || {}).each do |public_id, attrs|
      channel = voice_channels.find_by(public_id: public_id)
      next unless channel
      channel.update(
        voice_bitrate: attrs[:voice_bitrate],
        voice_user_limit: attrs[:voice_user_limit],
        video_enabled: attrs[:video_enabled] == "1"
      )
    end

    publish_server_state(:metadata)
    redirect_to server_settings_voice_path(@server), notice: "Voice settings updated."
  end

  def opt_in_voice
    unless current_user.livekit_configured?
      redirect_to server_settings_voice_path(@server), alert: "Configure your LiveKit credentials in User Settings > Voice first."
      return
    end

    svp = @server.server_voice_providers.new(user: current_user)
    if svp.save
      publish_server_state(:metadata)
      publish_server_state(:member, pubkey: current_user.nostr_public_key)
      redirect_to server_settings_voice_path(@server), notice: "You're now a voice provider for this server!"
    else
      redirect_to server_settings_voice_path(@server), alert: svp.errors.full_messages.join(", ")
    end
  end

  def opt_out_voice
    svp = @server.server_voice_providers.find_by(user: current_user)
    if svp
      svp.destroy
      publish_server_state(:metadata)
      publish_server_state(:member, pubkey: current_user.nostr_public_key)
      redirect_to server_settings_voice_path(@server), notice: "You've opted out as a voice provider."
    else
      redirect_to server_settings_voice_path(@server), alert: "You're not a voice provider for this server."
    end
  end

  def timeout_member
    ensure_kick_permission!
    membership = @server.server_memberships.find_by!(public_id: params[:id])
    return head :forbidden if membership.owner?

    duration = params[:duration].to_i
    membership.update!(timed_out_until: Time.current + duration.seconds, timed_out_by: current_user)

    ServerChannel.broadcast_to(@server, {
      type: "member_timeout",
      user_id: membership.user.public_id,
      timed_out_until: membership.timed_out_until.iso8601
    })
    publish_server_state(:member, pubkey: membership.user.nostr_public_key)

    respond_to do |format|
      format.json { render json: { success: true, timed_out_until: membership.timed_out_until.iso8601 } }
      format.html { redirect_to server_settings_members_path(@server), notice: "Member timed out." }
    end
  end

  def remove_timeout
    ensure_kick_permission!
    membership = @server.server_memberships.find_by!(public_id: params[:id])
    membership.update!(timed_out_until: nil, timed_out_by: nil)

    ServerChannel.broadcast_to(@server, {
      type: "member_timeout",
      user_id: membership.user.public_id,
      timed_out_until: nil
    })
    render json: { success: true }
  end

  def member_history
    ensure_mod_permission!

    # Try local membership first, fall back to remote
    membership = @server.server_memberships.find_by(public_id: params[:id])
    remote_member = @server.remote_members.find_by(public_id: params[:id]) unless membership
    raise ActiveRecord::RecordNotFound unless membership || remote_member

    @membership = membership
    @remote_member = remote_member
    @member_user = membership&.user
    @display_name = membership ? membership.user.display_name_for(@server) : remote_member.display_name_for(@server)
    @avatar_url = membership ? membership.user.effective_avatar_url : remote_member.effective_avatar_url
    @profile_color = (membership ? membership.user.profile_color : remote_member.try(:profile_color)) || "#1e1c1b"
    @username_initial = (membership ? membership.user.username : remote_member.username).to_s[0]&.upcase
    @member_tag = membership ? membership.user.tag : remote_member.tag
    @joined_at = membership&.joined_at || remote_member&.joined_at
    @last_online = membership&.user&.online_at
    @member_roles = membership ? membership.roles.sort_by { |r| -r.position } : remote_member.roles.sort_by { |r| -r.position }
    @is_owner = membership&.owner? || false

    channel_ids = @server.channels.pluck(:id)

    # Build scope that matches messages by local user_id OR nostr pubkey
    pubkey = @member_user&.nostr_public_key || remote_member&.pubkey
    if @member_user && pubkey.present?
      base_scope = Message.where(channel_id: channel_ids)
                          .where("user_id = :uid OR nostr_author_pubkey = :pk", uid: @member_user.id, pk: pubkey)
    elsif @member_user
      base_scope = Message.where(channel_id: channel_ids, user_id: @member_user.id)
    elsif pubkey.present?
      base_scope = Message.where(channel_id: channel_ids, nostr_author_pubkey: pubkey)
    else
      base_scope = Message.none
    end

    @total_messages = base_scope.count
    @image_count = base_scope.joins(files_attachments: :blob)
                             .where("active_storage_blobs.content_type LIKE 'image/%'")
                             .distinct.count
    @link_count = base_scope.where("content LIKE '%http%'").count
    @sticker_count = base_scope.where(is_sticker: true).count

    messages_scope = base_scope.includes(:channel, :user, files_attachments: :blob).order(created_at: :desc)

    if params[:channel_id].present?
      ch = @server.channels.find_by(public_id: params[:channel_id])
      messages_scope = messages_scope.where(channel_id: ch.id) if ch
    end

    page = [ params[:page].to_i, 1 ].max
    per_page = 25
    @messages = messages_scope.limit(per_page + 1).offset((page - 1) * per_page).to_a
    @has_more = @messages.size > per_page
    @messages = @messages.first(per_page)
    @page = page

    @channels = @server.channels.ordered
  end

  def prune_preview
    ensure_kick_permission!
    days = params[:days].to_i
    days = 7 if days < 1
    prunable = @server.prunable_memberships(days: days)
                      .includes(user: { avatar_attachment: :blob })
    render json: prunable.map { |m|
      { id: m.public_id, username: m.user.username, display_name: m.user.display_name_for(@server),
        avatar_url: m.user.effective_avatar_url, profile_color: m.user.profile_color || "#1e1c1b",
        last_online: m.user.online_at&.iso8601 }
    }
  end

  def prune_members
    ensure_kick_permission!
    days = params[:days].to_i
    days = 7 if days < 1
    prunable = @server.prunable_memberships(days: days)
    count = prunable.count
    prunable.find_each do |m|
      pubkey = m.user.nostr_public_key
      m.destroy
      publish_server_state(:member, pubkey: pubkey, removed: true) if pubkey.present?
    end
    render json: { success: true, pruned: count }
  end

  def batch_kick
    ensure_kick_permission!
    ids = Array(params[:member_ids])
    memberships = @server.server_memberships.where(public_id: ids).where.not(user: @server.owner)
    count = memberships.count
    memberships.find_each do |m|
      pubkey = m.user.nostr_public_key
      m.destroy
      publish_server_state(:member, pubkey: pubkey, removed: true) if pubkey.present?
    end
    render json: { success: true, kicked: count }
  end

  def batch_ban
    ensure_ban_permission!
    ids = Array(params[:member_ids])
    reason = params[:reason].presence
    memberships = @server.server_memberships.where(public_id: ids).where.not(user: @server.owner).includes(:user)
    count = 0
    memberships.find_each do |m|
      ban = @server.bans.new(user: m.user, banned_by: current_user, reason: reason)
      if ban.save
        publish_server_state(:ban, pubkey: m.user.nostr_public_key) if m.user.nostr_public_key.present?
        count += 1
      end
    end
    render json: { success: true, banned: count }
  end

  def batch_timeout
    ensure_kick_permission!
    ids = Array(params[:member_ids])
    duration = params[:duration].to_i
    memberships = @server.server_memberships.where(public_id: ids).where.not(user: @server.owner)
    until_time = Time.current + duration.seconds
    memberships.update_all(timed_out_until: until_time, timed_out_by_id: current_user.id)
    memberships.includes(:user).find_each do |m|
      ServerChannel.broadcast_to(@server, {
        type: "member_timeout",
        user_id: m.user.public_id,
        timed_out_until: until_time.iso8601
      })
    end
    render json: { success: true, timed_out: memberships.count }
  end

  def bans
    @bans = @server.bans.includes(user: { avatar_attachment: :blob }, banned_by: { avatar_attachment: :blob }).order(created_at: :desc)
  end

  def create_ban
    user = User.find_by(public_id: params[:user_id])
    remote_member = @server.remote_members.find_by(public_id: params[:user_id]) unless user

    if user
      ban = @server.bans.new(user: user, banned_by: current_user, reason: params[:reason])
      if ban.save
        publish_server_state(:ban, pubkey: user.nostr_public_key) if user.nostr_public_key.present?
        redirect_to server_settings_bans_path(@server), notice: "#{user.username} has been banned."
      else
        redirect_to server_settings_members_path(@server), alert: ban.errors.full_messages.join(", ")
      end
    elsif remote_member
      # Remote members have no local User record — remove and publish ban
      username = remote_member.username
      pubkey = remote_member.pubkey
      remote_member.destroy
      publish_server_state(:ban, pubkey: pubkey) if pubkey.present?
      redirect_to server_settings_members_path(@server), notice: "#{username} has been banned."
    else
      redirect_to server_settings_members_path(@server), alert: "User not found."
    end
  end

  def destroy_ban
    ban = @server.bans.find_by!(id: params[:ban_id])
    banned_pubkey = ban.user&.nostr_public_key
    ban.destroy
    publish_server_state(:ban, pubkey: banned_pubkey, unbanned: true) if banned_pubkey.present?
    redirect_to server_settings_bans_path(@server), notice: "Ban removed."
  end

  def onboarding
    @roles = @server.roles.where.not("json_extract(permissions, '$.owner') IS TRUE")
                          .where(name: nil..nil) # all non-owner
                          .ordered
    @roles = @server.roles.reject(&:owner?).sort_by { |r| -r.position }
    @channels = @server.channels.text.ordered
  end

  def update_onboarding
    @server.onboarding_enabled = params[:server][:onboarding_enabled] == "1"
    @server.onboarding_rules = params[:server][:onboarding_rules]

    # Self-assignable roles
    role_ids = Array(params[:server][:self_assignable_role_ids]).select(&:present?)
    @server.roles.update_all(self_assignable: false)
    @server.roles.where(public_id: role_ids).update_all(self_assignable: true)

    # Default channels
    @server.onboarding_default_channel_ids = Array(params[:server][:default_channel_ids]).select(&:present?)

    if @server.save
      redirect_to server_settings_onboarding_path(@server), notice: "Onboarding settings saved."
    else
      render :onboarding, status: :unprocessable_entity
    end
  end

  def relays
    @server_relays = @server.relay_urls || []
    @global_relays = RelayConnection.order(:url)
  end

  def add_relay
    url = params[:relay_url].to_s.strip
    if url.blank? || !url.match?(/\Awss?:\/\/.+/i)
      redirect_to server_settings_relays_path(@server), alert: "Invalid relay URL. Must start with wss:// or ws://"
      return
    end

    current_urls = @server.relay_urls || []
    unless current_urls.include?(url)
      @server.update!(relay_urls: current_urls + [ url ])
      # Also ensure it exists in the global relay pool
      RelayConnection.find_or_create_for_relay(url)
    end
    redirect_to server_settings_relays_path(@server), notice: "Relay added to server."
  end

  def remove_relay
    url = params[:relay_url].to_s.strip
    current_urls = @server.relay_urls || []
    @server.update!(relay_urls: current_urls - [ url ])
    redirect_to server_settings_relays_path(@server), notice: "Relay removed from server."
  end

  def verify_member
    ensure_kick_permission!
    verified_role = @server.roles.find_by(name: "Verified")
    unless verified_role
      respond_to do |format|
        format.html { redirect_to server_settings_members_path(@server), alert: "No Verified role exists on this server." }
        format.json { render json: { error: "No Verified role" }, status: :unprocessable_entity }
      end
      return
    end

    membership = @server.server_memberships.find_by(public_id: params[:id])
    unless membership
      respond_to do |format|
        format.html { redirect_to server_settings_members_path(@server), alert: "Member not found." }
        format.json { render json: { error: "Member not found" }, status: :not_found }
      end
      return
    end

    membership.roles << verified_role unless membership.roles.include?(verified_role)
    respond_to do |format|
      format.html { redirect_back fallback_location: server_settings_members_path(@server), notice: "#{membership.user.username} has been verified." }
      format.json { render json: { success: true, username: membership.user.username } }
    end
  end

  def unverify_member
    ensure_kick_permission!
    verified_role = @server.roles.find_by(name: "Verified")
    unless verified_role
      respond_to do |format|
        format.html { redirect_to server_settings_members_path(@server), alert: "No Verified role exists." }
        format.json { render json: { error: "No Verified role" }, status: :unprocessable_entity }
      end
      return
    end

    membership = @server.server_memberships.find_by(public_id: params[:id])
    unless membership
      respond_to do |format|
        format.html { redirect_to server_settings_members_path(@server), alert: "Member not found." }
        format.json { render json: { error: "Member not found" }, status: :not_found }
      end
      return
    end

    membership.roles.delete(verified_role)
    respond_to do |format|
      format.html { redirect_back fallback_location: server_settings_members_path(@server), notice: "#{membership.user.username} verification removed." }
      format.json { render json: { success: true, username: membership.user.username } }
    end
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_current_membership
    @current_membership = @server.server_memberships.find_by(user: current_user)
  end

  def ensure_permission!
    unless @current_membership&.has_permission?("manage_server") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
    end
  end

  def ensure_invite_permission!
    unless @current_membership&.has_permission?("create_invite") || @current_membership&.has_permission?("manage_invites") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
    end
  end

  def ensure_emoji_permission!
    unless @current_membership&.has_permission?("create_emojis") || @current_membership&.has_permission?("manage_emojis") || @current_membership&.has_permission?("manage_server") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
    end
  end

  def ensure_relay_permission!
    unless @current_membership&.has_permission?("manage_server") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
    end
  end

  def ensure_sticker_permission!
    unless @current_membership&.has_permission?("create_stickers") || @current_membership&.has_permission?("manage_emojis") || @current_membership&.has_permission?("manage_server") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
    end
  end

  def build_members_list
    memberships = @server.server_memberships.includes(:membership_roles, :roles, user: { avatar_attachment: :blob }).order(joined_at: :desc)
    remote_members = @server.remote_members.includes(:remote_membership_roles, :roles).order(joined_at: :desc)

    # Index local memberships by pubkey so we can skip duplicate remotes
    local_pubkeys = memberships.filter_map { |m| m.user.nostr_public_key }

    members = memberships.map { |m|
      {
        display_name: m.user.display_name_for(@server),
        tag: m.user.tag,
        joined_at: m.joined_at,
        roles: m.roles.sort_by { |r| -r.position },
        avatar_url: m.user.effective_avatar_url,
        profile_color: m.user.try(:profile_color) || "#1e1c1b",
        initial: m.user.username[0]&.upcase,
        public_id: m.public_id,
        owner: m.owner?,
        kick_path: server_settings_kick_member_path(@server, m),
        ban_user_id: m.user.public_id,
        confirm_name: m.user.username,
        role_ids: m.roles.reject(&:owner?).map(&:public_id),
        timed_out: m.timed_out?,
        timed_out_until: m.timed_out_until&.iso8601
      }
    }

    remote_members.each do |r|
      next if local_pubkeys.include?(r.pubkey)
      members << {
        display_name: r.display_name_for(@server),
        tag: r.tag,
        joined_at: r.joined_at,
        roles: r.roles.sort_by { |rr| -rr.position },
        avatar_url: r.effective_avatar_url,
        profile_color: r.try(:profile_color) || "#1e1c1b",
        initial: (r.username.presence || r.pubkey[0..1]).to_s[0]&.upcase,
        public_id: r.public_id,
        owner: false,
        kick_path: server_settings_kick_remote_member_path(@server, r),
        ban_user_id: r.public_id,
        confirm_name: r.display_name_for(@server),
        role_ids: r.roles.map(&:public_id),
        timed_out: false,
        timed_out_until: nil
      }
    end

    members.sort_by! { |m| m[:joined_at] || Time.at(0) }.reverse!
    members
  end

  def ensure_kick_permission!
    unless @current_membership&.has_permission?("kick_members") || @current_membership&.admin?
      render json: { error: "Permission denied" }, status: :forbidden
    end
  end

  def ensure_ban_permission!
    unless @current_membership&.has_permission?("ban_members") || @current_membership&.admin?
      render json: { error: "Permission denied" }, status: :forbidden
    end
  end

  def ensure_mod_permission!
    unless @current_membership&.has_permission?("kick_members") || @current_membership&.has_permission?("ban_members") || @current_membership&.has_permission?("manage_server") || @current_membership&.admin?
      redirect_to server_settings_members_path(@server), alert: "Permission denied."
    end
  end

  def broadcast_member_update(membership)
    user = membership.user.reload
    html = render_to_string(
      partial: "servers/member_item",
      locals: { member: user, server: @server },
      layout: false,
      formats: [ :html ]
    )
    ServerChannel.broadcast_to(@server, {
      type: "member_update",
      user_id: user.public_id,
      html: html,
      display_name: user.display_name_for(@server),
      username: user.username,
      tag: user.tag,
      role_color: user.role_color_for(@server)
    })
  end

  def server_params
    params.require(:server).permit(:name, :description, :icon, :banner, :discoverable, :age_restricted, :welcome_message_enabled, :welcome_channel_id, :welcome_message_template)
  end

  def publish_server_state(event_type, **options)
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, event_type.to_s, **options)
  end
end
