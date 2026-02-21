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
    resources :gif_collections, only: [:index, :create, :update, :destroy]
    resources :gif_favorites, only: [:index, :create, :update, :destroy] do
      collection do
        post :toggle
      end
    end
  end

  # Server folders
  resources :server_folders, only: [:create, :update, :destroy] do
    member do
      patch :toggle_collapse
    end
  end

  # Servers
  patch :reorder_servers, to: "servers#reorder_servers"
  resources :servers, only: [:show, :new, :create, :edit, :update, :destroy] do
    member do
      post :join
      delete :leave
    end
    resources :channels, only: [:show, :new, :create, :edit, :update, :destroy] do
      member do
        get :older_messages
        get :newer_messages
        get :around_messages
        post :bridge, controller: "shared_channels"
        delete :unbridge, controller: "shared_channels"
      end
    end
    resources :categories, only: [:new, :create, :edit, :update, :destroy]
    patch :reorder_channels, to: "channel_reorder#update"
    patch :reorder_roles, to: "roles#reorder"
    delete "channels/:id/quick_delete", to: "channel_reorder#destroy_channel", as: :quick_delete_channel
    delete "categories/:id/quick_delete", to: "channel_reorder#destroy_category", as: :quick_delete_category
    resources :members, only: [:index, :update, :destroy], controller: "server_members" do
      member do
        get :profile_card, controller: "member_cards"
        get :context_menu, controller: "member_cards"
      end
    end
    resources :roles, except: [:show]
    resources :emojis, only: [:index, :create, :destroy], controller: "server_emojis"
    resources :stickers, only: [:index, :create, :destroy], controller: "server_stickers"
  end

  # Server settings
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
    resources :messages, only: [:create, :edit, :update, :destroy] do
      member do
        post :toggle_reaction, controller: "reactions", action: "toggle"
        get :reactions_list, controller: "reactions", action: "list"
      end
    end
  end

  # Invites
  get "inferno/invite/:code", to: "invites#show", as: :invite
  post "inferno/invite/:code/accept", to: "invites#accept", as: :accept_invite
  get "invite/:code", to: redirect("/inferno/invite/%{code}")
  post "invite/:code/accept", to: "invites#accept"

  # Conversations (DMs)
  resources :conversations, only: [:index, :show, :create, :destroy] do
    member do
      post :accept
    end
    resources :dm_messages, only: [:create, :update, :destroy] do
      member do
        post :toggle_reaction, controller: "dm_reactions", action: "toggle"
      end
    end
  end

  # Friends
  resources :friendships, only: [:index, :create, :destroy] do
    member do
      post :accept
      post :decline
      post :ignore
    end
  end

  # Blocks
  resources :blocks, only: [:create, :destroy]

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
  get "settings/keybinds", to: "settings#keybinds", as: :user_settings_keybinds
  get "settings/password", to: "settings#change_password", as: :user_settings_password
  patch "settings/password", to: "settings#update_password", as: :settings_update_password
  post "settings/reveal_nostr_key", to: "settings#reveal_nostr_key", as: :reveal_nostr_key
  post "settings/export_encrypted_key", to: "settings#export_encrypted_key", as: :export_encrypted_key
  resource :profile, only: [:show, :edit, :update]

  # User cards
  resources :users, only: [] do
    member do
      get :card, to: "user_cards#show"
    end
  end
end
