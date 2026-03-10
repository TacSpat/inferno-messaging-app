class AddSafetySettingsAndContentHashes < ActiveRecord::Migration[8.1]
  def change
    # Safety filter settings on instance_configs
    add_column :instance_configs, :safety_keyword_filter, :text, default: ""
    add_column :instance_configs, :safety_hide_unknown_senders, :boolean, default: false
    add_column :instance_configs, :safety_report_threshold, :integer, default: 0
    add_column :instance_configs, :safety_reputation_enabled, :boolean, default: false
    add_column :instance_configs, :safety_reputation_threshold, :integer, default: 30
    add_column :instance_configs, :safety_reputation_sensitivity, :string, default: "moderate"
    add_column :instance_configs, :safety_image_hash_enabled, :boolean, default: false

    # Perceptual hash store for flagged images/video frames
    create_table :content_hashes do |t|
      t.string :hash_value, null: false
      t.string :hash_type, null: false, default: "dhash"
      t.string :media_type # image, video_frame
      t.string :original_filename
      t.references :message, foreign_key: true
      t.timestamps
    end

    add_index :content_hashes, [:hash_value, :hash_type]
  end
end
