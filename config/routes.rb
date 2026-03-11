Rails.application.routes.draw do
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?
  devise_for :users, controllers: {
    sessions: "users/sessions"
  }

  # Setup wizard (first-run)
  get "setup", to: "setup#new", as: :setup
  post "setup", to: "setup#create"

  # NIP-05 Nostr identity verification
  get "/.well-known/nostr.json", to: "nostr/well_known#show", as: :nostr_well_known

  # Nostr relay search (NIP-50 + NIP-05 resolution)
  get "nostr/search", to: "nostr/search#show", as: :nostr_search

  # Blossom server (content-addressable file storage)
  get "blossom/list", to: "blossom#list", as: :blossom_list
  get "blossom/:sha256", to: "blossom#show", as: :blossom_show
  match "blossom/:sha256", to: "blossom#check", via: :head
  put "blossom/upload", to: "blossom#upload", as: :blossom_upload

  # Multi-device sync
  post "sync/refresh", to: "sync#refresh"

  get "up" => "rails/health#show", as: :rails_health_check

  authenticated :user do
    root "conversations#index", as: :authenticated_root
  end
  devise_scope :user do
    root "devise/sessions#new"
  end

  # Tenor API proxy & GIF collections
  namespace :api do
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
  post :resolve_server_preview, to: "servers#resolve_preview"
  resources :servers, only: [ :show, :new, :create, :edit, :update, :destroy ] do
    member do
      post :join
      delete :leave
      get :search
      get :onboarding
      post :complete_onboarding
    end
    resources :channels, only: [ :show, :new, :create, :edit, :update, :destroy ] do
      member do
        get :older_messages
        get :newer_messages
        get :around_messages
        get :eligible_sidechat_channels
        post :bridge, controller: "shared_channels"
        delete :unbridge, controller: "shared_channels"
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
    resources :roles, except: [ :show ] do
      member do
        get :members
        post :toggle_member
      end
    end
    resources :emojis, only: [ :index, :create, :destroy ], controller: "server_emojis"
    resources :stickers, only: [ :index, :create, :destroy ], controller: "server_stickers"

    # Voice channels
    post "voice/join/:channel_id", to: "voice_channels#join", as: :voice_join
    post "voice/rejoin/:channel_id", to: "voice_channels#rejoin", as: :voice_rejoin
    delete "voice/leave", to: "voice_channels#leave", as: :voice_leave
    post "voice/leave", to: "voice_channels#leave"  # sendBeacon compatibility
    post "voice/monitor/:channel_id", to: "voice_channels#monitor", as: :voice_monitor

    # Voice showcases
    resources :voice_showcases, only: [ :create, :destroy ] do
      member do
        post :approve
        post :deny
      end
      collection do
        post :request_speak
      end
    end

    # Voice moderation
    get "voice/context_menu/:user_id", to: "voice_moderation#context_menu", as: :voice_context_menu
    patch "voice/server_mute/:user_id", to: "voice_moderation#server_mute", as: :voice_server_mute
    patch "voice/server_deafen/:user_id", to: "voice_moderation#server_deafen", as: :voice_server_deafen
    delete "voice/disconnect/:user_id", to: "voice_moderation#disconnect_member", as: :voice_disconnect
    patch "voice/move/:user_id", to: "voice_moderation#move_member", as: :voice_move
  end

  # Voice state updates (not scoped to server — user has one active state)
  patch "voice_states/self_mute", to: "voice_states#self_mute"
  patch "voice_states/self_deafen", to: "voice_states#self_deafen"
  patch "voice_states/screen_share", to: "voice_states#screen_share"
  patch "voice_states/video", to: "voice_states#video"
  patch "voice_states/broadcasting", to: "voice_states#broadcasting"

  # Server settings
  scope "servers/:server_id/settings", as: "server_settings" do
    get "/", to: redirect { |params| "/servers/#{params[:server_id]}/settings/overview" }
    get "overview", to: "server_settings#overview", as: :overview
    patch "overview", to: "server_settings#update_overview", as: :update_overview
    get "members", to: "server_settings#members", as: :members
    patch "members/:id", to: "server_settings#update_member", as: :update_member
    delete "members/:id", to: "server_settings#kick_member", as: :kick_member
    delete "remote_members/:id", to: "server_settings#kick_remote_member", as: :kick_remote_member
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
    get "voice", to: "server_settings#voice", as: :voice
    patch "voice", to: "server_settings#update_voice", as: :update_voice
    post "voice/opt_in", to: "server_settings#opt_in_voice", as: :voice_opt_in
    delete "voice/opt_out", to: "server_settings#opt_out_voice", as: :voice_opt_out

    # Member management
    post "members/:id/timeout", to: "server_settings#timeout_member", as: :timeout_member
    post "members/:id/remove_timeout", to: "server_settings#remove_timeout", as: :remove_timeout
    get  "members/:id/history", to: "server_settings#member_history", as: :member_history

    get    "prune_preview", to: "server_settings#prune_preview", as: :prune_preview
    delete "prune",         to: "server_settings#prune_members",  as: :prune_members

    post   "batch_kick",    to: "server_settings#batch_kick",    as: :batch_kick
    post   "batch_ban",     to: "server_settings#batch_ban",     as: :batch_ban
    post   "batch_timeout", to: "server_settings#batch_timeout", as: :batch_timeout

    # Verification
    post "members/:id/verify", to: "server_settings#verify_member", as: :verify_member
    post "members/:id/unverify", to: "server_settings#unverify_member", as: :unverify_member

    # Relays
    get "relays", to: "server_settings#relays", as: :relays
    post "relays", to: "server_settings#add_relay", as: :add_relay
    delete "relays", to: "server_settings#remove_relay", as: :remove_relay

    # Onboarding
    get "onboarding", to: "server_settings#onboarding", as: :onboarding
    patch "onboarding", to: "server_settings#update_onboarding", as: :update_onboarding
  end

  # Mentions autocomplete
  get "servers/:server_id/mentions", to: "mentions#search", as: :server_mentions
  get "servers/:server_id/search_autocomplete", to: "mentions#search_autocomplete", as: :server_search_autocomplete

  # Channel messages
  resources :channels, only: [] do
    resources :messages, only: [ :create, :edit, :update, :destroy ] do
      collection do
        get :pinned
      end
      member do
        post :toggle_reaction, controller: "reactions", action: "toggle"
        get :reactions_list, controller: "reactions", action: "list"
        post :toggle_pin
      end
    end
  end

  # Invites (new format with nostr_group_id)
  get "inferno/invite/:nostr_group_id/:code", to: "invites#show", as: :nostr_invite
  post "inferno/invite/:nostr_group_id/:code/accept", to: "invites#accept", as: :accept_nostr_invite
  # Legacy format (backwards compat)
  get "inferno/invite/:code", to: "invites#show", as: :invite
  post "inferno/invite/:code/accept", to: "invites#accept", as: :accept_invite
  get "invite/:code", to: redirect("/inferno/invite/%{code}")
  post "invite/:code/accept", to: "invites#accept"

  # Nostr-native server links (resolve via relay, no invite code needed)
  get "inferno/server/:nostr_group_id", to: "nostr_servers#show", as: :nostr_server
  post "inferno/server/:nostr_group_id/join", to: "nostr_servers#join", as: :join_nostr_server
  get "inferno/server/:nostr_group_id/sync_status", to: "nostr_servers#sync_status", as: :nostr_server_sync_status

  # Conversations (DMs & group chats)
  resources :conversations, only: [ :index, :show, :create, :update, :destroy ] do
    member do
      post :accept
      post :decline
      post :add_member
      delete :remove_member
    end
    resources :dm_messages, only: [ :create, :update, :destroy ] do
      collection do
        get :older_messages
        get :newer_messages
        get :pinned
        get :search
      end
      member do
        post :toggle_reaction, controller: "dm_reactions", action: "toggle"
        post :toggle_pin
      end
    end
    resources :calls, only: [ :create ] do
      member do
        post :accept
        post :decline
        post :join
        post :hangup
      end
    end
  end

  # Friends
  resources :friendships, only: [ :index, :create, :destroy ] do
    member do
      post :accept
      post :decline
      post :ignore
    end
  end

  # Blocks
  resources :blocks, only: [ :create, :destroy ]

  # Notifications
  post "notifications/mark_read", to: "notifications#mark_read"
  post "notifications/mark_dm_read", to: "notifications#mark_dm_read"

  # User settings
  get "settings", to: redirect("/settings/account")
  get "settings/account", to: "settings#my_account", as: :user_settings_account
  get "settings/profile", to: "settings#profile", as: :user_settings_profile
  patch "settings/profile", to: "settings#update_profile", as: :settings_profile
  get "settings/appearance", to: "settings#appearance", as: :user_settings_appearance
  patch "settings/appearance", to: "settings#update_appearance", as: :settings_update_appearance
  get "settings/notifications", to: "settings#notifications", as: :user_settings_notifications
  patch "settings/notifications", to: "settings#update_notifications"
  get "settings/keybinds", to: "settings#keybinds", as: :user_settings_keybinds
  get "settings/password", to: "settings#change_password", as: :user_settings_password
  patch "settings/password", to: "settings#update_password", as: :settings_update_password
  post "settings/dismiss_hint", to: "settings#dismiss_hint", as: :dismiss_hint_settings
  post "settings/reset_hints", to: "settings#reset_hints", as: :reset_hints_settings
  post "settings/dismiss_all_hints", to: "settings#dismiss_all_hints", as: :dismiss_all_hints_settings
  post "settings/reveal_nostr_key", to: "settings#reveal_nostr_key", as: :reveal_nostr_key
  post "settings/export_encrypted_key", to: "settings#export_encrypted_key", as: :export_encrypted_key
  get "settings/voice", to: "settings#voice", as: :user_settings_voice
  patch "settings/voice", to: "settings#update_voice", as: :settings_update_voice
  post "settings/voice/verify", to: "settings#verify_voice", as: :settings_verify_voice
  get "settings/relays", to: "settings#relays", as: :user_settings_relays
  post "settings/relays", to: "settings#add_relay", as: :settings_add_relay
  delete "settings/relays", to: "settings#remove_relay", as: :settings_remove_relay
  post "settings/relays/toggle", to: "settings#toggle_relay", as: :settings_toggle_relay
  post "settings/relays/check", to: "settings#check_relay", as: :settings_check_relay
  # Storage & Cache
  get "settings/storage", to: "settings#storage", as: :user_settings_storage
  patch "settings/storage", to: "settings#update_storage"
  post "settings/clear_cache", to: "settings#clear_cache", as: :user_settings_clear_cache
  post "settings/run_prune", to: "settings#run_prune", as: :user_settings_run_prune
  # Content Safety
  get "settings/safety", to: "settings#safety", as: :user_settings_safety
  patch "settings/safety", to: "settings#update_safety"
  post "settings/hide_message/:id", to: "settings#hide_message", as: :user_settings_hide_message
  post "settings/unhide_message/:id", to: "settings#unhide_message", as: :user_settings_unhide_message
  # Report to authorities
  get "settings/authority_report/:id", to: "settings#authority_report", as: :user_settings_authority_report
  post "settings/generate_authority_report/:id", to: "settings#generate_authority_report", as: :user_settings_generate_authority_report

  resource :profile, only: [ :show, :edit, :update ]

  # User cards
  resources :users, only: [] do
    member do
      get :card, to: "user_cards#show"
    end
  end
end
