class ServerSettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_current_membership
  before_action :ensure_permission!, except: [ :invites, :create_invite, :destroy_invite, :update_member, :emojis, :stickers, :voice, :opt_in_voice, :opt_out_voice ]
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
    @memberships = @server.server_memberships.includes(:membership_roles, :roles, user: { avatar_attachment: :blob }).order(joined_at: :desc)
    @remote_members = @server.remote_members.includes(:remote_membership_roles, :roles).order(joined_at: :desc)
    @all_roles = @server.roles.where.not("json_extract(permissions, '$.owner') = ?", true).ordered
  end

  def update_member
    membership = @server.server_memberships.find_by!(public_id: params[:id])
    is_self = membership.user == current_user

    # Handle nickname update
    if params.key?(:nickname)
      # Self can change own nickname, admins/manage_roles can change anyone's
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

    role_ids = Array(params[:role_ids])
    roles = @server.roles.where(public_id: role_ids).reject(&:owner?)

    # Owner role cannot be removed from the server owner
    owner_role = membership.roles.find(&:owner?)
    roles << owner_role if owner_role

    membership.roles = roles
    broadcast_member_update(membership)
    publish_server_state(:member, pubkey: membership.user.nostr_public_key)

    respond_to do |format|
      format.json do
        render json: {
          success: true,
          roles: membership.roles.ordered.map { |r| { id: r.public_id, name: r.name, color: r.color, position: r.position } }
        }
      end
      format.html do
        redirect_to server_settings_members_path(@server), notice: "Roles updated for #{membership.user.username}."
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

  def ensure_sticker_permission!
    unless @current_membership&.has_permission?("create_stickers") || @current_membership&.has_permission?("manage_emojis") || @current_membership&.has_permission?("manage_server") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
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
    params.require(:server).permit(:name, :description, :icon, :banner, :welcome_message_enabled, :welcome_channel_id, :welcome_message_template)
  end

  def publish_server_state(event_type, **options)
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, event_type.to_s, **options)
  end
end
