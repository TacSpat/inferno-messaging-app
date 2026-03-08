module Nostr
  class WellKnownController < ApplicationController
    def show
      name = params[:name]&.downcase

      if name.blank?
        render json: { names: {}, relays: {} }
        return
      end

      user = User.where("LOWER(username) = ?", name)
                  .where.not(nostr_public_key: nil)
                  .first

      if user
        # Include externally-reachable relay URLs for discovery (NIP-05 + NIP-46)
        relay_urls = RelayConnection.externally_reachable.pluck(:url)
        instance_relay = LocalConfig.current.effective_instance_relay_url
        if instance_relay.present? && instance_relay.start_with?("wss://") && !relay_urls.include?(instance_relay)
          relay_urls.unshift(instance_relay)
        end
        relay_map = {}
        relay_map[user.nostr_public_key] = relay_urls if relay_urls.any?

        response = {
          names: { name => user.nostr_public_key },
          relays: relay_map
        }
      else
        response = { names: {}, relays: {} }
      end

      render json: response
    end
  end
end
