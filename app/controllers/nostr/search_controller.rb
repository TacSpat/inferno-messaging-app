module Nostr
  class SearchController < ApplicationController
    before_action :authenticate_user!

    # GET /nostr/search?q=alice
    def show
      query = params[:q].to_s.strip
      if query.blank?
        render json: []
        return
      end

      results = NostrSearchService.search(query)

      render json: results.map { |r|
        npub = begin
          Nostr::Bech32.encode_npub(r.pubkey)
        rescue
          nil
        end

        {
          pubkey: r.pubkey,
          npub: npub,
          display_name: r.display_name,
          name: r.name,
          avatar_url: r.avatar_url,
          nip05: r.nip05,
          bio: r.bio,
          contact_status: r.contact_status
        }
      }
    end
  end
end
