class SetupController < ApplicationController
  before_action :redirect_if_setup_complete

  def new
  end

  def create
    @user = User.new(setup_params)
    @user.email = "owner@localhost" # Devise requires email, but we don't use it
    @user.theme = "inferno"

    if params[:nostr_private_key].present?
      # Import existing keypair
      begin
        private_key = params[:nostr_private_key].strip
        # Handle nsec format
        if private_key.start_with?("nsec")
          private_key = Nostr::Bech32.decode_nsec(private_key)
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
    # If no key provided, HasNostrIdentity callback will generate one

    if @user.save
      seed_default_relays
      # Publish profile (Kind 0) and relay list (Kind 10002) to Nostr relays
      NostrPublishJob.perform_later(@user.id, :profile)
      NostrPublishJob.perform_later(@user.id, :relay_list)
      sign_in(@user)
      redirect_to authenticated_root_path, notice: "Welcome to Inferno!"
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def setup_params
    params.require(:user).permit(:username, :password, :password_confirmation)
  end

  def redirect_if_setup_complete
    redirect_to root_path if User.any?
  end

  def seed_default_relays
    default_relays = %w[
      wss://relay.damus.io
      wss://nos.lol
      wss://relay.snort.social
    ]
    default_relays.each do |url|
      RelayConnection.find_or_create_for_relay(url)
    end
  end
end
