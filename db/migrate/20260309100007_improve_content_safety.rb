class ImproveContentSafety < ActiveRecord::Migration[8.1]
  def change
    # Extend content_hashes for shared registry + allowlisting
    add_column :content_hashes, :source, :string, default: "local"
    add_column :content_hashes, :reporter_pubkeys, :json, default: []
    add_column :content_hashes, :reporter_count, :integer, default: 1
    add_column :content_hashes, :confidence, :float, default: 1.0
    add_column :content_hashes, :allowlisted, :boolean, default: false
    add_column :content_hashes, :nostr_event_ids, :json, default: []
    add_index :content_hashes, :allowlisted
    add_index :content_hashes, :source

    # Shared hash settings on instance_configs
    add_column :instance_configs, :safety_shared_hashes_enabled, :boolean, default: false
    add_column :instance_configs, :safety_shared_hash_min_reporters, :integer, default: 3
    add_column :instance_configs, :safety_shared_hash_trust_friends, :boolean, default: true
    add_column :instance_configs, :safety_publish_hashes, :boolean, default: true

    # Keyword preset toggles on instance_configs
    add_column :instance_configs, :safety_block_links, :boolean, default: false
    add_column :instance_configs, :safety_block_phone_numbers, :boolean, default: false
    add_column :instance_configs, :safety_block_all_caps, :boolean, default: false
    add_column :instance_configs, :safety_block_spam_chars, :boolean, default: false
  end
end
