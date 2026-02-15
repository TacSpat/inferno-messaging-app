Rails.application.routes.draw do
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?
  devise_for :users, controllers: {
    registrations: "users/registrations",
    sessions: "users/sessions",
    confirmations: "users/confirmations"
  }

  get "users/check_email", to: "home#check_email", as: :users_check_email

  get "up" => "rails/health#show", as: :rails_health_check

  authenticated :user do
    root "conversations#index", as: :authenticated_root
  end
  devise_scope :user do
    root "devise/sessions#new"
  end

  # Servers
  resources :servers, only: [:new, :create, :edit, :update, :destroy] do
    member do
      post :join
      delete :leave
    end
    resources :channels, only: [:show, :new, :create, :edit, :update, :destroy] do
      member do
        get :older_messages
        get :newer_messages
        get :around_messages
      end
    end
    resources :categories, only: [:new, :create, :edit, :update, :destroy]
    patch :reorder_channels, to: "channel_reorder#update"
    delete "channels/:id/quick_delete", to: "channel_reorder#destroy_channel", as: :quick_delete_channel
    delete "categories/:id/quick_delete", to: "channel_reorder#destroy_category", as: :quick_delete_category
    resources :members, only: [:index, :update, :destroy], controller: "server_members" do
      member do
        get :profile_card, controller: "member_cards"
        get :context_menu, controller: "member_cards"
      end
    end
    resources :roles, except: [:show]
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
  get "invite/:code", to: "invites#show", as: :invite
  post "invite/:code/accept", to: "invites#accept", as: :accept_invite

  # Conversations (DMs)
  resources :conversations, only: [:index, :show, :create, :destroy] do
    member do
      post :accept
    end
    resources :dm_messages, only: [:create, :update, :destroy]
  end

  # Friends
  resources :friendships, only: [:index, :create, :destroy] do
    member do
      post :accept
      post :decline
    end
  end

  # Blocks
  resources :blocks, only: [:create, :destroy]

  # Notifications
  post "notifications/mark_read", to: "notifications#mark_read"
  post "notifications/mark_dm_read", to: "notifications#mark_dm_read"

  # User profile
  # User settings (modal sections)
  get "settings/:section", to: "settings#show", as: :settings_section
  patch "settings/profile", to: "settings#update_profile", as: :settings_profile
  resource :profile, only: [:show, :edit, :update]
end
