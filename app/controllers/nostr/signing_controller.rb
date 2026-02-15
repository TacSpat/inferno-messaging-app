module Nostr
  class SigningController < ApplicationController
    before_action :authenticate_user!
    before_action :validate_params

    # GET /auth/nostr/sign?challenge=<nonce>&callback=<url>&requesting_domain=<domain>
    # Show confirmation: "remote.chat wants to verify your identity"
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

      # Build callback URL with the signed event and optional profile info
      callback_params = {
        event: encoded_event,
        username: current_user.username,
        display_name: current_user.display_name
      }

      redirect_url = "#{callback}?#{callback_params.to_query}"
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
