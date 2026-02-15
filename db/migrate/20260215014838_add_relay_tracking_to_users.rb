class AddRelayTrackingToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :nostr_profile_published_at, :datetime
    add_column :users, :nostr_contacts_published_at, :datetime
  end
end
