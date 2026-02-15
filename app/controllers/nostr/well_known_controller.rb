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
        response = {
          names: { name => user.nostr_public_key },
          relays: {}
        }
      else
        response = { names: {}, relays: {} }
      end

      render json: response
    end
  end
end
