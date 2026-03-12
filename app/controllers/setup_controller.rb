class SetupController < ApplicationController
  before_action :redirect_if_setup_complete

  def new
  end

  def create
    @user = User.new(setup_params)
    @user.email = "owner@localhost" # Devise requires email, but we don't use it
    @user.theme = "inferno"

    migrate_mode = params[:setup_mode] == "migrate"

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
      # Apply fetched profile fields
      @user.display_name = params[:fetched_display_name].presence
      @user.bio = params[:fetched_bio].presence
      @user.avatar_url = params[:fetched_avatar_url].presence
      @user.banner_url = params[:fetched_banner_url].presence
    end

    if @user.save
      extra_relay_urls = migrate_mode ? Array(params[:fetched_relays]).select(&:present?) : []
      seed_relays(extra_relay_urls)

      NostrPublishJob.perform_later(@user.id, :profile)
      NostrPublishJob.perform_later(@user.id, :relay_list)

      if migrate_mode
        MigrateIdentityJob.perform_later(@user.id)
      end

      sign_in(@user)
      redirect_to authenticated_root_path, notice: "Welcome to Inferno!"
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

  private

  def setup_params
    params.require(:user).permit(:username, :password, :password_confirmation)
  end

  def redirect_if_setup_complete
    redirect_to root_path if User.any?
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
