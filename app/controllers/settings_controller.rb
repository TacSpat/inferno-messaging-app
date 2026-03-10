class SettingsController < ApplicationController
  before_action :authenticate_user!
  layout "user_settings"

  def my_account
    @user = current_user
  end

  def profile
    @user = current_user
  end

  def update_profile
    @user = current_user
    if @user.update(profile_params)
      # Model callback covers scalar field changes, but avatar/banner
      # attachment changes don't trigger saved_change_to_*, so broadcast
      # explicitly when attachments were included in the update.
      if profile_params[:avatar].present? || profile_params[:banner].present?
        @user.broadcast_profile_update
        if @user.nostr_public_key.present?
          NostrPublishJob.perform_later(@user.id, :profile)
          @user.publish_member_events
        end
      end
      redirect_to user_settings_profile_path, notice: "Profile updated!"
    else
      render :profile, status: :unprocessable_entity
    end
  end

  def appearance
    @user = current_user
  end

  def update_appearance
    @user = current_user
    if @user.update(theme: params[:theme])
      redirect_to user_settings_appearance_path, notice: "Appearance updated!"
    else
      render :appearance, status: :unprocessable_entity
    end
  end

  def notifications
    @user = current_user
  end

  def keybinds
    @user = current_user
  end

  def change_password
    @user = current_user
  end

  def update_password
    @user = current_user

    unless @user.valid_password?(params[:current_password])
      flash.now[:alert] = "Current password is incorrect."
      render :change_password, status: :unprocessable_entity
      return
    end

    if params[:new_password].blank?
      flash.now[:alert] = "New password can't be blank."
      render :change_password, status: :unprocessable_entity
      return
    end

    if params[:new_password] != params[:new_password_confirmation]
      flash.now[:alert] = "New passwords don't match."
      render :change_password, status: :unprocessable_entity
      return
    end

    if @user.update(password: params[:new_password], password_confirmation: params[:new_password_confirmation])
      bypass_sign_in(@user)
      redirect_to user_settings_account_path, notice: "Password updated successfully."
    else
      flash.now[:alert] = @user.errors.full_messages.join(", ")
      render :change_password, status: :unprocessable_entity
    end
  end

  def voice
    @user = current_user
  end

  def update_voice
    @user = current_user

    # User-level voice settings (stored in user.voice_settings JSON)
    voice_settings = @user.voice_settings || {}
    voice_settings["noise_suppression"] = params[:noise_suppression] == "1"
    voice_settings["echo_cancellation"] = params[:echo_cancellation] != "0"
    voice_settings["auto_gain_control"] = params[:auto_gain_control] != "0"
    voice_settings["input_mode"] = params[:input_mode].presence || "voice_activity"

    # LiveKit credentials (available to all users)
    if params[:livekit_section].present?
      @user.livekit_url = params[:livekit_url].presence
      @user.livekit_api_key = params[:livekit_api_key].presence
      @user.livekit_api_secret = params[:livekit_api_secret] if params[:livekit_api_secret].present?

      if @user.livekit_url_changed? || @user.livekit_api_key_changed? || @user.livekit_api_secret_enc_changed?
        @user.livekit_verified = false
        @user.livekit_verified_at = nil
      end
    end

    @user.update!(voice_settings: voice_settings)

    redirect_to user_settings_voice_path, notice: "Voice settings saved!"
  rescue => e
    flash.now[:alert] = e.message
    render :voice, status: :unprocessable_entity
  end

  def verify_voice
    result = LivekitVerifier.verify!(user: current_user)
    render json: { success: result.success, message: result.message }
  end

  def reveal_nostr_key
    if current_user.valid_password?(params[:password])
      render json: { nsec: current_user.nsec }, layout: false
    else
      render json: { error: "Incorrect password" }, status: :unprocessable_entity, layout: false
    end
  end

  def export_encrypted_key
    unless current_user.valid_password?(params[:password])
      render json: { error: "Incorrect password" }, status: :unprocessable_entity, layout: false
      return
    end

    backup_password = params[:backup_password]
    if backup_password.blank? || backup_password.length < 8
      render json: { error: "Backup password must be at least 8 characters" }, status: :unprocessable_entity, layout: false
      return
    end

    ncryptsec = Nip49Service.encrypt(
      current_user.nostr_private_key,
      backup_password,
      log_n: 16,
      key_security: 0x02
    )

    render json: { ncryptsec: ncryptsec }, layout: false
  rescue => e
    render json: { error: "Encryption failed: #{e.message}" }, status: :internal_server_error, layout: false
  end

  def relays
    @relays = RelayConnection.order(:url)
  end

  def add_relay
    url = params[:relay_url].to_s.strip
    if url.blank? || !url.match?(/\Awss?:\/\/.+/i)
      redirect_to user_settings_relays_path, alert: "Invalid relay URL. Must start with wss:// or ws://"
      return
    end

    relay = RelayConnection.find_or_create_for_relay(url)
    if relay
      relay.enable! if relay.disabled?
      RelaySubscriptionManager.instance.refresh_connections if RelaySubscriptionManager.instance.running
      redirect_to user_settings_relays_path, notice: "Relay added."
    else
      redirect_to user_settings_relays_path, alert: "Failed to add relay."
    end
  end

  def remove_relay
    relay = RelayConnection.find_by(id: params[:relay_id])
    if relay
      relay.destroy
      RelaySubscriptionManager.instance.refresh_connections if RelaySubscriptionManager.instance.running
      redirect_to user_settings_relays_path, notice: "Relay removed."
    else
      redirect_to user_settings_relays_path, alert: "Relay not found."
    end
  end

  def toggle_relay
    relay = RelayConnection.find_by(id: params[:relay_id])
    if relay
      relay.active? ? relay.disable! : relay.enable!
      RelaySubscriptionManager.instance.refresh_connections if RelaySubscriptionManager.instance.running
      redirect_to user_settings_relays_path, notice: "Relay #{relay.active? ? 'enabled' : 'disabled'}."
    else
      redirect_to user_settings_relays_path, alert: "Relay not found."
    end
  end

  def check_relay
    relay = RelayConnection.find_by(id: params[:relay_id])
    unless relay
      render json: { error: "Relay not found" }, status: :not_found
      return
    end

    begin
      result = RelayService.fetch_from_relay(relay.url, { kinds: [0], limit: 1 })
      relay.mark_connected!
      render json: { status: "ok", message: "Connected successfully" }
    rescue => e
      relay.mark_error!(e.message)
      render json: { status: "error", message: e.message }
    end
  end

  # === Storage & Cache ===

  def storage
    @config = LocalConfig.current
    @db_size = begin
      db_path = ActiveRecord::Base.connection.execute("PRAGMA database_list").first["file"]
      db_path.present? && File.exist?(db_path) ? File.size(db_path) : nil
    rescue
      nil
    end
    @message_count = Message.count
    @visible_message_count = Message.visible.count
    @attachment_count = ActiveStorage::Attachment.where(record_type: "Message", name: "files").count
    @cache_dir = Rails.root.join("public", "cached_assets")
    if @cache_dir.exist?
      @cache_files = Dir.glob(@cache_dir.join("**", "*")).select { |f| File.file?(f) }
      @cache_size = @cache_files.sum { |f| File.size(f) }
      @cache_count = @cache_files.size
    else
      @cache_size = 0
      @cache_count = 0
    end
  end

  def update_storage
    config = LocalConfig.current
    config.update!(
      max_cache_size_mb: params[:max_cache_size_mb].to_i,
      backfill_days: params[:backfill_days].to_i,
      backfill_enabled: params[:backfill_enabled] == "1",
      pruning_strategy: params[:pruning_strategy],
      message_retention_days: params[:message_retention_days].to_i,
      attachment_retention_days: params[:attachment_retention_days].to_i,
      max_db_size_mb: params[:max_db_size_mb].to_i,
      keep_pinned_messages: params[:keep_pinned_messages] == "1",
      prune_channel_messages: params[:prune_channel_messages] == "1",
      prune_dm_messages: params[:prune_dm_messages] == "1"
    )
    redirect_to user_settings_storage_path, notice: "Storage settings saved."
  rescue => e
    redirect_to user_settings_storage_path, alert: e.message
  end

  def clear_cache
    cache_dir = Rails.root.join("public", "cached_assets")
    count = 0
    if cache_dir.exist?
      files = Dir.glob(cache_dir.join("**", "*")).select { |f| File.file?(f) }
      count = files.size
      files.each { |f| File.delete(f) }
    end
    redirect_to user_settings_storage_path, notice: "Cleared #{count} cached #{'file'.pluralize(count)}."
  end

  # === Content Safety ===

  def safety
    @config = LocalConfig.current
    @hidden_messages = Message.where.not(hidden_at: nil)
      .includes(:hidden_attachment_records, :channel, :conversation)
      .order(hidden_at: :desc)
    @content_hash_count = ContentHash.count
    @local_hash_count = ContentHash.local_hashes.count
    @shared_hash_count = ContentHash.shared_hashes.count
    @allowlisted_hash_count = ContentHash.allowlisted_hashes.count
    @auto_hidden_count = Message.where("hidden_reason LIKE ?", "auto:%").count
  end

  def update_safety
    config = LocalConfig.current
    config.update!(
      safety_keyword_filter: params[:safety_keyword_filter].to_s,
      safety_hide_unknown_senders: params[:safety_hide_unknown_senders] == "1",
      safety_report_threshold: params[:safety_report_threshold].to_i,
      safety_reputation_enabled: params[:safety_reputation_enabled] == "1",
      safety_reputation_threshold: params[:safety_reputation_threshold].to_i,
      safety_reputation_sensitivity: params[:safety_reputation_sensitivity],
      safety_image_hash_enabled: params[:safety_image_hash_enabled] == "1",
      # Shared hash settings
      safety_shared_hashes_enabled: params[:safety_shared_hashes_enabled] == "1",
      safety_shared_hash_min_reporters: params[:safety_shared_hash_min_reporters].to_i,
      safety_shared_hash_trust_friends: params[:safety_shared_hash_trust_friends] == "1",
      safety_publish_hashes: params[:safety_publish_hashes] == "1",
      # Keyword presets
      safety_block_links: params[:safety_block_links] == "1",
      safety_block_phone_numbers: params[:safety_block_phone_numbers] == "1",
      safety_block_all_caps: params[:safety_block_all_caps] == "1",
      safety_block_spam_chars: params[:safety_block_spam_chars] == "1"
    )
    redirect_to user_settings_safety_path, notice: "Safety settings saved."
  rescue => e
    redirect_to user_settings_safety_path, alert: e.message
  end

  def remove_allowlist
    hash = ContentHash.find_by(id: params[:hash_id])
    if hash
      hash.update!(allowlisted: false)
      redirect_to user_settings_safety_path, notice: "Removed from allowlist."
    else
      redirect_to user_settings_safety_path, alert: "Hash not found."
    end
  end

  def clear_shared_hashes
    count = ContentHash.shared_hashes.delete_all
    redirect_to user_settings_safety_path, notice: "Cleared #{count} shared hash#{'es' unless count == 1}."
  end

  def hide_message
    message = Message.find_by!(public_id: params[:id])
    reason = params[:reason].presence || "other"
    message.hide!(current_user, reason: reason)
    respond_to do |format|
      format.html { redirect_to user_settings_safety_path, notice: "Message hidden." }
      format.json { render json: { status: "ok" } }
    end
  end

  def unhide_message
    message = Message.find_by!(public_id: params[:id])
    message.unhide!
    redirect_to user_settings_safety_path, notice: "Message unhidden."
  end

  def run_prune
    PruneMessagesJob.perform_later
    redirect_to user_settings_storage_path, notice: "Prune job queued."
  end

  private

  def profile_params
    params.require(:user).permit(:username, :display_name, :bio, :status, :status_emoji, :avatar, :banner, :profile_color, :profile_color_2, :banner_offset_y)
  end
end
