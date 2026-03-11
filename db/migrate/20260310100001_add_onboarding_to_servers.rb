class AddOnboardingToServers < ActiveRecord::Migration[8.0]
  def change
    add_column :servers, :onboarding_enabled, :boolean, default: false, null: false
    add_column :servers, :onboarding_rules, :text
    add_column :servers, :onboarding_self_assignable_role_ids, :json, default: []
    add_column :servers, :onboarding_default_channel_ids, :json, default: []

    add_column :server_memberships, :onboarding_completed, :boolean, default: false, null: false

    add_column :roles, :self_assignable, :boolean, default: false, null: false
  end
end
