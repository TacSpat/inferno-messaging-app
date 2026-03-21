class SetupController < ApplicationController
  before_action :redirect_if_setup_complete, only: [ :new, :create, :fetch_profile ]

  def new
  end

  def create
    migrate_mode = params[:setup_mode] == "migrate"

    user_attrs = if migrate_mode
      { username: params[:migrate_username], password: params[:migrate_password], password_confirmation: params[:migrate_password_confirmation] }
    else
      setup_params
    end

    @user = User.new(user_attrs)
    @user.email = "owner@localhost" # Devise requires email, but we don't use it
    @user.theme = "inferno"

    private_key_raw = params[:migrate_private_key] if migrate_mode

    if private_key_raw.present?
      begin
        private_key = private_key_raw.strip
        if private_key.start_with?("nsec")
          private_key = Nostr::Bech32.decode(private_key)[:data]
        end
        public_key = Nostr::Key.get_public_key(private_key)
        encryptor = ActiveSupport::MessageEncryptor.new(
          ActiveSupport::KeyGenerator.new(
            Rails.application.secret_key_base
          ).generate_key("nostr keypair encryption", 32)
        )
        @user.nostr_public_key = public_key
        @user.nostr_encrypted_private_key = encryptor.encrypt_and_sign(private_key)
      rescue => e
        @user.errors.add(:base, "Invalid Nostr private key: #{e.message}")
        render :new, status: :unprocessable_entity
        return
      end
    end

    if migrate_mode
      # Apply fetched profile fields (avatar/banner are Active Storage, handled via Nostr Kind 0)
      @user.display_name = params[:fetched_display_name].presence
      @user.bio = params[:fetched_bio].presence
    end

    if @user.save
      if migrate_mode
        attach_profile_media(@user, params[:fetched_avatar_url], params[:fetched_banner_url])
      end

      extra_relay_urls = migrate_mode ? Array(params[:fetched_relays]).select(&:present?) : []
      seed_relays(extra_relay_urls)

      NostrPublishJob.perform_later(@user.id, :profile)
      NostrPublishJob.perform_later(@user.id, :relay_list)

      sign_in(@user)

      if migrate_mode
        # Initialize progress cache before enqueueing
        Rails.cache.write("migrate_identity:#{@user.id}", { step: "starting", progress: 0 }, expires_in: 5.minutes)
        MigrateIdentityJob.perform_later(@user.id)
        redirect_to setup_migration_status_path
      else
        redirect_to authenticated_root_path, notice: "Welcome to Inferno!", status: :see_other
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  def fetch_profile
    private_key = params[:private_key].to_s.strip
    relay_urls = Array(params[:relay_urls]).select(&:present?)

    begin
      if private_key.start_with?("nsec")
        private_key = Nostr::Bech32.decode(private_key)[:data]
      end
      pubkey = Nostr::Key.get_public_key(private_key)
    rescue => e
      render json: { error: "Invalid private key: #{e.message}" }, status: :unprocessable_entity
      return
    end

    # Use provided relays + defaults
    query_urls = relay_urls.presence || %w[wss://relay.damus.io wss://nos.lol wss://relay.snort.social]

    # Fetch Kind 0 (profile) and Kind 10002 (relay list)
    profile_events = []
    relay_events = []
    query_urls.each do |url|
      profile_events.concat(RelayService.fetch_from_relay(url, { kinds: [0], authors: [pubkey], limit: 1 }, timeout: 10))
      relay_events.concat(RelayService.fetch_from_relay(url, { kinds: [10002], authors: [pubkey], limit: 1 }, timeout: 10))
    rescue => e
      Rails.logger.debug("[Setup] Relay #{url} fetch error: #{e.message}")
    end

    # Parse profile from newest Kind 0
    profile = {}
    if profile_events.any?
      newest = profile_events.max_by { |e| e["created_at"].to_i }
      metadata = JSON.parse(newest["content"]) rescue {}
      profile = {
        username: metadata["name"],
        display_name: metadata["display_name"].presence || metadata["name"],
        bio: metadata["about"],
        avatar_url: metadata["picture"],
        banner_url: metadata["banner"],
        nip05: metadata["nip05"]
      }
    end

    # Parse relays from newest Kind 10002
    relays = []
    if relay_events.any?
      newest = relay_events.max_by { |e| e["created_at"].to_i }
      tags = newest["tags"] || []
      relays = tags.select { |t| t[0] == "r" }.map { |t| t[1] }.compact.uniq
    end

    render json: {
      pubkey: pubkey,
      found: profile_events.any?,
      **profile,
      relays: relays
    }
  end

  def migration_status
    user = current_user || User.owner
    unless user
      render json: { step: "failed", progress: 0, error: "No user found" }
      return
    end

    data = Rails.cache.read("migrate_identity:#{user.id}")
    data ||= { step: "waiting", progress: 0 }

    if data[:step] == "complete"
      data[:redirect_url] = authenticated_root_path
    end

    render json: data
  end

  private

  def setup_params
    params.require(:user).permit(:username, :password, :password_confirmation)
  end

  def redirect_if_setup_complete
    redirect_to root_path if User.any?
  end

  def attach_profile_media(user, avatar_url, banner_url)
    [ [ avatar_url, :avatar ], [ banner_url, :banner ] ].each do |url, attachment_name|
      next if url.blank?
      local_path = RemoteAssetCache.cache(url)
      next unless local_path
      full_path = Rails.root.join("public", local_path.delete_prefix("/"))
      next unless File.exist?(full_path)
      content_type = Marcel::MimeType.for(Pathname.new(full_path))
      ext = File.extname(full_path)
      user.public_send(attachment_name).attach(
        io: File.open(full_path),
        filename: "#{attachment_name}#{ext}",
        content_type: content_type
      )
    end
  rescue => e
    Rails.logger.warn("[Setup] Failed to attach profile media: #{e.message}")
  end

  def seed_relays(extra_urls = [])
    default_relays = %w[
      wss://relay.damus.io
      wss://nos.lol
      wss://relay.snort.social
    ]
    (default_relays + extra_urls).uniq.each do |url|
      RelayConnection.find_or_create_for_relay(url)
    end
  end
end
