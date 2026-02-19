module Nostr
  class SigningController < ApplicationController
    before_action :authenticate_user!
    before_action :validate_params

    # GET /auth/nostr/sign?challenge=<nonce>&callback=<url>&requesting_domain=<domain>
    # Show brief confirmation with profile info, then auto-approve after a moment.
    def show
      @requesting_domain = params[:requesting_domain]
      @challenge = params[:challenge]
      @callback = params[:callback]
    end

    # POST /auth/nostr/sign
    # Sign the challenge and redirect back to the remote instance
    def create
      challenge = params[:challenge]
      callback = params[:callback]
      requesting_domain = params[:requesting_domain]

      # Build and sign NIP-42 auth event
      signed_event = NostrEventService.build_auth_event(
        user: current_user,
        challenge: challenge,
        relay_url: callback
      )

      # Base64 encode the event for URL transport
      encoded_event = Base64.urlsafe_encode64(JSON.generate(signed_event))

      # Generate federation token for the requesting instance
      federation_token = FederationTokenService.generate(
        pubkey: current_user.nostr_public_key,
        requesting_instance: requesting_domain
      )

      AuditService.log(
        event_type: "token_issued",
        actor: current_user,
        remote_domain: requesting_domain,
        ip_address: request.remote_ip,
        metadata: { pubkey: current_user.nostr_public_key }
      )

      # Build callback URL with the signed event and optional profile info
      # Note: home_instance is already embedded in the callback URL by the
      # requesting instance's auth controller — don't re-add it here as
      # instance_domain may lack the port number in development.
      callback_params = {
        event: encoded_event,
        username: current_user.username,
        display_name: current_user.display_name,
        home_relay: InstanceConfig.current.instance_relay_url,
        profile_color: current_user.profile_color,
        discriminator: current_user.discriminator,
        federation_token: federation_token
      }

      separator = callback.include?("?") ? "&" : "?"
      redirect_url = "#{callback}#{separator}#{callback_params.to_query}"
      redirect_to redirect_url, allow_other_host: true
    end

    private

    def validate_params
      if params[:challenge].blank? || params[:callback].blank? || params[:requesting_domain].blank?
        redirect_to root_path, alert: "Invalid authentication request."
      end
    end
  end
end
