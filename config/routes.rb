Rails.application.routes.draw do
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?
  devise_for :users, controllers: {
    registrations: "users/registrations",
    sessions: "users/sessions",
    confirmations: "users/confirmations"
  }

  get "users/check_email", to: "home#check_email", as: :users_check_email

  # Instance administration
  namespace :admin do
    resource :instance_config, only: [ :show, :update ] do
      post :emergency_lockdown
      post :lift_lockdown
    end
    resources :instance_blocklists, only: [ :create, :destroy ]
    resources :relay_connections, only: [ :create, :destroy ] do
      member do
        post :toggle
      end
    end
    resources :moderation_reports, only: [ :index, :show ] do
      member do
        post :review
      end
    end
    resources :audit_logs, only: [ :index ]
    resources :legal_holds, only: [ :index, :create, :destroy ]
    resources :data_exports, only: [ :index, :create ] do
      member do
        get :download
      end
    end
    resources :user_suspensions, only: [ :index, :create, :destroy ]
  end

  # NIP-05 Nostr identity verification
  get "/.well-known/nostr.json", to: "nostr/well_known#show", as: :nostr_well_known
  get "/.well-known/instance.json", to: "nostr/instance_metadata#show", as: :instance_metadata

  # Federation API (cross-instance server creation)
  namespace :federation do
    post :create_server, to: "servers#create"
    get "profiles/:pubkey", to: "profiles#show", as: :federation_profile
    get "profiles/:pubkey/servers", to: "profiles#servers", as: :federation_profile_servers
    get "profiles/:pubkey/conversations", to: "profiles#conversations", as: :federation_profile_conversations
    get "profiles/:pubkey/friends", to: "profiles#friends", as: :federation_profile_friends
    get "profiles/:pubkey/folders", to: "profiles#folders", as: :federation_profile_folders
    get "profiles/:pubkey/gif_collections", to: "profiles#gif_collections", as: :federation_profile_gif_collections
    get "profiles/:pubkey/memberships", to: "profiles#memberships", as: :federation_profile_memberships
    post "profiles/:pubkey/report_memberships", to: "profiles#report_memberships", as: :federation_profile_report_memberships
    get "syncing", to: "syncing#show", as: :syncing

    # Cross-instance friend requests
    post "users/lookup", to: "friend_requests#lookup"
    post "friend_requests", to: "friend_requests#create"
    post "friend_requests/respond", to: "friend_requests#respond"
    post "conversations/push_reference", to: "friend_requests#push_conversation_reference"
  end

  # Cross-instance Nostr authentication
  # Remote instance side: initiate auth + receive callback
  get  "auth/nostr",          to: "nostr/auth#new",      as: :nostr_auth
  get  "auth/nostr/callback", to: "nostr/auth#callback",  as: :nostr_auth_callback

  # Home instance side: sign challenge for remote instance
  get  "auth/nostr/sign",     to: "nostr/signing#show",   as: :nostr_auth_sign
  post "auth/nostr/sign",     to: "nostr/signing#create"

  get "up" => "rails/health#show", as: :rails_health_check

  authenticated :user do
    root "conversations#index", as: :authenticated_root
  end
  devise_scope :user do
    root "devise/sessions#new"
  end

  # Tenor API proxy & GIF collections
  namespace :api do
    post "federation_sync", to: "federation_sync#create"
    get "tenor/search", to: "tenor#search"
    get "tenor/trending", to: "tenor#trending"
    get "tenor/categories", to: "tenor#categories"
    resources :gif_collections, only: [ :index, :create, :update, :destroy ]
    resources :gif_favorites, only: [ :index, :create, :update, :destroy ] do
      collection do
        post :toggle
      end
    end
  end

  # Server folders
  resources :server_folders, only: [ :create, :update, :destroy ] do
    member do
      patch :toggle_collapse
    end
  end

  # Servers
  patch :reorder_servers, to: "servers#reorder_servers"
  resources :servers, only: [ :show, :new, :create, :edit, :update, :destroy ] do
    member do
      post :join
      delete :leave
    end
    resources :channels, only: [ :show, :new, :create, :edit, :update, :destroy ] do
      member do
        get :older_messages
        get :newer_messages
        get :around_messages
        post :bridge, controller: "shared_channels"
        delete :unbridge, controller: "shared_channels"
        post :join_voice, to: "voice_channels#join"
        post :refresh_voice_token, to: "voice_channels#refresh_token"
        delete :leave_voice, to: "voice_channels#leave"
      end
    end
    resources :categories, only: [ :new, :create, :edit, :update, :destroy ]
    patch :reorder_channels, to: "channel_reorder#update"
    patch :reorder_roles, to: "roles#reorder"
    delete "channels/:id/quick_delete", to: "channel_reorder#destroy_channel", as: :quick_delete_channel
    delete "categories/:id/quick_delete", to: "channel_reorder#destroy_category", as: :quick_delete_category
    resources :members, only: [ :index, :update, :destroy ], controller: "server_members" do
      member do
        get :profile_card, controller: "member_cards"
        get :context_menu, controller: "member_cards"
      end
    end
    resources :roles, except: [ :show ]
    resources :emojis, only: [ :index, :create, :destroy ], controller: "server_emojis"
    resources :stickers, only: [ :index, :create, :destroy ], controller: "server_stickers"
  end

  # Server settings (separate namespace for cleaner route names)
  scope "servers/:server_id/settings", as: "server_settings" do
    get "/", to: redirect { |params| "/servers/#{params[:server_id]}/settings/overview" }
    get "overview", to: "server_settings#overview", as: :overview
    patch "overview", to: "server_settings#update_overview", as: :update_overview
    get "members", to: "server_settings#members", as: :members
    patch "members/:id", to: "server_settings#update_member", as: :update_member
    delete "members/:id", to: "server_settings#kick_member", as: :kick_member
    get "roles", to: "server_settings#roles", as: :roles
    get "invites", to: "server_settings#invites", as: :invites
    post "invites", to: "server_settings#create_invite", as: :create_invite
    delete "invites", to: "server_settings#destroy_invite", as: :destroy_invite
    get "audit_log", to: "server_settings#audit_log", as: :audit_log
    get "bans", to: "server_settings#bans", as: :bans
    post "bans", to: "server_settings#create_ban", as: :create_ban
    delete "bans", to: "server_settings#destroy_ban", as: :destroy_ban
    get "emojis", to: "server_settings#emojis", as: :emojis
    get "stickers", to: "server_settings#stickers", as: :stickers
  end

  # Mentions autocomplete
  get "servers/:server_id/mentions", to: "mentions#search", as: :server_mentions

  # Channel messages
  resources :channels, only: [] do
    resources :messages, only: [ :create, :edit, :update, :destroy ] do
      member do
        post :toggle_reaction, controller: "reactions", action: "toggle"
        get :reactions_list, controller: "reactions", action: "list"
      end
    end
  end

  # Invites
  get "invite/:code", to: "invites#show", as: :invite
  post "invite/:code/accept", to: "invites#accept", as: :accept_invite

  # Conversations (DMs)
  resources :conversations, only: [ :index, :show, :create, :destroy ] do
    member do
      post :accept
    end
    resources :dm_messages, only: [ :create, :update, :destroy ]
  end

  # Friends
  resources :friendships, only: [ :index, :create, :destroy ] do
    member do
      post :accept
      post :decline
    end
  end

  # Blocks
  resources :blocks, only: [ :create, :destroy ]

  # Moderation reports (user-facing)
  resources :moderation_reports, only: [ :create ]

  # LiveKit webhooks
  post "/livekit/webhooks", to: "livekit_webhooks#create"

  # Voice state self-updates
  patch "voice_states/self_mute", to: "voice_states#self_mute"
  patch "voice_states/self_deafen", to: "voice_states#self_deafen"

  # Voice participant context menu & moderation
  resources :voice_states, only: [] do
    member do
      get :context_menu
      patch :server_mute
      patch :server_deafen
      post :kick
      post :move
    end
  end

  # Notifications
  post "notifications/mark_read", to: "notifications#mark_read"
  post "notifications/mark_dm_read", to: "notifications#mark_dm_read"

  # User settings (full-page layout with sidebar)
  get "settings", to: redirect("/settings/account")
  get "settings/account", to: "settings#my_account", as: :user_settings_account
  get "settings/profile", to: "settings#profile", as: :user_settings_profile
  patch "settings/profile", to: "settings#update_profile", as: :settings_profile
  get "settings/appearance", to: "settings#appearance", as: :user_settings_appearance
  get "settings/notifications", to: "settings#notifications", as: :user_settings_notifications
  get "settings/keybinds", to: "settings#keybinds", as: :user_settings_keybinds
  post "settings/reveal_nostr_key", to: "settings#reveal_nostr_key", as: :reveal_nostr_key
  post "settings/export_encrypted_key", to: "settings#export_encrypted_key", as: :export_encrypted_key
  resource :profile, only: [ :show, :edit, :update ]
end
