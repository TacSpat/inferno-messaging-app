module Nostr
  class AuthController < ApplicationController
    skip_before_action :verify_authenticity_token, only: [:callback]

    # GET /auth/nostr?home_instance=home.chat
    # Start the remote auth flow: generate challenge, redirect to home instance
    def new
      home_instance = params[:home_instance]&.strip&.downcase

      if home_instance.blank?
        redirect_to root_path, alert: "Home instance is required."
        return
      end

      # Check federation mode
      config = InstanceConfig.current
      if config.federation_closed?
        redirect_to root_path, alert: "This instance does not accept remote authentication."
        return
      end

      if config.remote_auth_blocked?
        redirect_to root_path, alert: "Remote authentication is currently disabled."
        return
      end

      # Check blocklist
      if InstanceBlocklist.blocked?(home_instance)
        redirect_to root_path, alert: "Authentication from #{home_instance} is not allowed."
        return
      end

      # Embed home_instance in the callback URL (sessions are unreliable
      # when both instances share localhost cookies in dev)
      callback_with_home = "#{nostr_auth_callback_url}?home_instance=#{CGI.escape(home_instance)}"

      # Create challenge
      challenge = NostrAuthChallenge.create!(
        nonce: SecureRandom.hex(32),
        requesting_domain: request.host_with_port,
        callback_url: callback_with_home,
        expires_at: 5.minutes.from_now
      )

      # Redirect to home instance's signing endpoint
      protocol = Rails.env.development? ? "http" : "https"
      home_signing_url = "#{protocol}://#{home_instance}/auth/nostr/sign?" + {
        challenge: challenge.nonce,
        callback: challenge.callback_url,
        requesting_domain: request.host_with_port
      }.to_query

      redirect_to home_signing_url, allow_other_host: true
    end

    # GET /auth/nostr/callback?event=<base64-encoded-signed-event>
    # Receive the signed challenge from home instance, verify, create session
    def callback
      event_param = params[:event]
      if event_param.blank?
        redirect_to root_path, alert: "Missing authentication event."
        return
      end

      # Decode the event
      begin
        event_json = Base64.urlsafe_decode64(event_param)
        event_data = JSON.parse(event_json)
      rescue StandardError
        redirect_to root_path, alert: "Invalid authentication event format."
        return
      end

      # Extract challenge nonce from event tags
      challenge_tag = (event_data["tags"] || []).find { |t| t[0] == "challenge" }
      unless challenge_tag
        redirect_to root_path, alert: "Authentication event missing challenge."
        return
      end

      nonce = challenge_tag[1]

      # Find and validate the challenge
      challenge = NostrAuthChallenge.valid_for_nonce(nonce).first
      unless challenge
        redirect_to root_path, alert: "Invalid or expired authentication challenge."
        return
      end

      # Verify the signed event
      begin
        verified_event = NostrEventService.verify_auth_event(
          event_data,
          expected_challenge: nonce
        )
      rescue NostrEventService::InvalidSignature, NostrEventService::InvalidEvent => e
        Rails.logger.warn("Nostr auth verification failed: #{e.message}")
        redirect_to root_path, alert: "Authentication verification failed."
        return
      end

      pubkey = verified_event["pubkey"]

      # Home instance is passed through the callback URL params
      home_instance = params[:home_instance]&.strip&.downcase

      if home_instance.present?
        # Check blocklist again with the verified home instance
        if InstanceBlocklist.blocked?(home_instance)
          redirect_to root_path, alert: "Authentication from #{home_instance} is not allowed."
          return
        end

        nip05_verified = verify_nip05(pubkey, home_instance)
        unless nip05_verified
          Rails.logger.warn("NIP-05 verification failed for pubkey #{pubkey} on #{home_instance}")
          # Don't block — NIP-05 is optional, but log it
        end
      end

      # Consume the challenge (one-time use)
      challenge.consume!

      # Find or create remote user + shadow user
      remote_user = RemoteUser.find_or_create_from_auth(
        public_key: pubkey,
        home_instance: home_instance || "unknown",
        username: params[:username],
        display_name: params[:display_name],
        profile_color: params[:profile_color],
        discriminator: params[:discriminator]
      )

      # Store federation token for API access to home instance
      if params[:federation_token].present?
        remote_user.update!(federation_token: params[:federation_token])
      end

      remote_user.reload
      shadow_user = remote_user.shadow_user

      # Sign in the shadow user via Devise
      sign_in(shadow_user)

      # Enqueue background profile sync from home instance
      FederationProfileSyncJob.perform_later(remote_user.id)

      # Auto-create relay connection for home instance
      if params[:home_relay].present?
        RelayConnection.find_or_create_for_relay(params[:home_relay])
      end

      # Redeem pending invite
      if (code = session.delete(:pending_invite_code))
        invite = Invite.find_by(code: code)
        if invite&.usable?
          server = invite.server
          unless shadow_user.servers.include?(server)
            if shadow_user.remote? && InstanceConfig.current.remote_joins_blocked?
              redirect_to root_path, alert: "Remote user joins are currently disabled."
              return
            end
            invite.increment_uses!
            server.server_memberships.create!(user: shadow_user)
          end
          redirect_to server_channel_path(server, server.channels.ordered.first),
                      notice: "Welcome to #{server.name}!"
          return
        end
      end

      redirect_to root_path, notice: "Authenticated via #{home_instance || 'remote instance'}."
    end

    private

    def extract_home_instance(relay_url)
      return nil if relay_url.blank?
      uri = URI.parse(relay_url)
      return nil if uri.host.blank?
      # Include port for non-standard ports (important for dev with localhost)
      default_port = (uri.scheme == "wss" || uri.scheme == "https") ? 443 : 80
      if uri.port && uri.port != default_port
        "#{uri.host}:#{uri.port}"
      else
        uri.host
      end
    rescue URI::InvalidURIError
      nil
    end

    def verify_nip05(pubkey, home_instance)
      # Try to find the user's NIP-05 identifier on the home instance
      # We don't know their username, so we check cached NIP-05 entries
      cached = Nip05Cache.valid.find_by(public_key: pubkey)
      if cached
        cached_domain = cached.identifier.split("@").last
        return cached_domain == home_instance
      end

      # No cache hit — we can't verify without knowing the username
      # The home instance will be trusted based on the signed challenge
      true
    end
  end
end
