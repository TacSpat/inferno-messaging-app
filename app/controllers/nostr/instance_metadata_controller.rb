module Nostr
  class InstanceMetadataController < ApplicationController
    def show
      config = InstanceConfig.current

      render json: {
        name: config.instance_name,
        description: config.instance_description,
        domain: Rails.application.config.x.instance_domain,
        version: "0.1.0",
        limits: {
          max_users: config.max_users,
          max_servers: config.max_servers,
          max_channels_per_server: config.max_channels_per_server,
          max_members_per_server: config.max_members_per_server,
          max_upload_size_mb: config.max_upload_size_mb
        },
        usage: {
          users: User.count,
          servers: Server.count
        },
        federation: {
          mode: config.federation_mode,
          relay: config.instance_relay_url,
          lockdown: config.lockdown?,
          nostr_well_known: "/.well-known/nostr.json",
          auth_endpoint: "/auth/nostr",
          signing_endpoint: "/auth/nostr/sign"
        }
      }
    end
  end
end
