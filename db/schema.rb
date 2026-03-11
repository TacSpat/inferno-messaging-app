# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_10_100002) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "bans", force: :cascade do |t|
    t.bigint "banned_by_id", null: false
    t.datetime "created_at", null: false
    t.text "reason"
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["banned_by_id"], name: "index_bans_on_banned_by_id"
    t.index ["server_id", "user_id"], name: "index_bans_on_server_id_and_user_id", unique: true
    t.index ["server_id"], name: "index_bans_on_server_id"
    t.index ["user_id"], name: "index_bans_on_user_id"
  end

  create_table "blocks", force: :cascade do |t|
    t.bigint "blocked_id", null: false
    t.bigint "blocker_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blocked_id"], name: "index_blocks_on_blocked_id"
    t.index ["blocker_id", "blocked_id"], name: "index_blocks_on_blocker_id_and_blocked_id", unique: true
    t.index ["blocker_id"], name: "index_blocks_on_blocker_id"
  end

  create_table "call_participants", force: :cascade do |t|
    t.integer "call_id", null: false
    t.datetime "created_at", null: false
    t.integer "duration_seconds"
    t.datetime "joined_at"
    t.datetime "left_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["call_id", "user_id"], name: "index_call_participants_on_call_id_and_user_id", unique: true
    t.index ["call_id"], name: "index_call_participants_on_call_id"
    t.index ["user_id"], name: "index_call_participants_on_user_id"
  end

  create_table "calls", force: :cascade do |t|
    t.integer "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.integer "initiated_by_id", null: false
    t.string "livekit_room_name"
    t.string "public_id", limit: 12, null: false
    t.datetime "started_at"
    t.string "status", default: "ringing"
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "status"], name: "index_calls_on_conversation_id_and_status"
    t.index ["conversation_id"], name: "index_calls_on_conversation_id"
    t.index ["initiated_by_id"], name: "index_calls_on_initiated_by_id"
    t.index ["public_id"], name: "index_calls_on_public_id", unique: true
  end

  create_table "categories", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.integer "position"
    t.string "public_id", limit: 12, null: false
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_categories_on_public_id", unique: true
    t.index ["server_id"], name: "index_categories_on_server_id"
  end

  create_table "channel_reads", force: :cascade do |t|
    t.bigint "channel_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_read_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["channel_id"], name: "index_channel_reads_on_channel_id"
    t.index ["user_id", "channel_id"], name: "index_channel_reads_on_user_id_and_channel_id", unique: true
    t.index ["user_id"], name: "index_channel_reads_on_user_id"
  end

  create_table "channels", force: :cascade do |t|
    t.bigint "category_id"
    t.string "channel_public_key"
    t.integer "channel_type"
    t.datetime "created_at", null: false
    t.integer "current_voice_provider_id"
    t.boolean "encrypted", default: false
    t.text "encrypted_channel_private_key"
    t.string "name"
    t.string "nostr_group_id"
    t.string "nostr_relay_url"
    t.json "nostr_relay_urls"
    t.boolean "nsfw"
    t.bigint "parent_channel_id"
    t.json "permissions_overrides"
    t.integer "position"
    t.boolean "post_only", default: false
    t.string "public_id", limit: 12, null: false
    t.bigint "server_id", null: false
    t.boolean "shared", default: false
    t.integer "sidechat_channel_id"
    t.text "topic"
    t.datetime "updated_at", null: false
    t.boolean "video_enabled", default: false
    t.integer "voice_bitrate", default: 64000
    t.integer "voice_user_limit", default: 0
    t.index ["category_id"], name: "index_channels_on_category_id"
    t.index ["current_voice_provider_id"], name: "index_channels_on_current_voice_provider_id"
    t.index ["nostr_group_id"], name: "index_channels_on_nostr_group_id"
    t.index ["parent_channel_id"], name: "index_channels_on_parent_channel_id"
    t.index ["public_id"], name: "index_channels_on_public_id", unique: true
    t.index ["server_id"], name: "index_channels_on_server_id"
    t.index ["sidechat_channel_id"], name: "index_channels_on_sidechat_channel_id"
  end

  create_table "contacts", force: :cascade do |t|
    t.string "avatar_url"
    t.string "banner_url"
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.integer "friendship_status", default: 0, null: false
    t.datetime "last_seen_at"
    t.string "nip05"
    t.string "petname"
    t.datetime "profile_fetched_at"
    t.string "pubkey", null: false
    t.string "relay_url"
    t.integer "report_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["friendship_status"], name: "index_contacts_on_friendship_status"
    t.index ["pubkey"], name: "index_contacts_on_pubkey", unique: true
  end

  create_table "content_hashes", force: :cascade do |t|
    t.boolean "allowlisted", default: false
    t.float "confidence", default: 1.0
    t.datetime "created_at", null: false
    t.string "hash_type", default: "dhash", null: false
    t.string "hash_value", null: false
    t.string "media_type"
    t.integer "message_id"
    t.json "nostr_event_ids", default: []
    t.string "original_filename"
    t.integer "reporter_count", default: 1
    t.json "reporter_pubkeys", default: []
    t.string "source", default: "local"
    t.datetime "updated_at", null: false
    t.index ["allowlisted"], name: "index_content_hashes_on_allowlisted"
    t.index ["hash_value", "hash_type"], name: "index_content_hashes_on_hash_value_and_hash_type"
    t.index ["message_id"], name: "index_content_hashes_on_message_id"
    t.index ["source"], name: "index_content_hashes_on_source"
  end

  create_table "conversation_participants", force: :cascade do |t|
    t.boolean "accepted", default: false, null: false
    t.integer "contact_id"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_read_at"
    t.boolean "muted", default: false, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["contact_id"], name: "index_conversation_participants_on_contact_id"
    t.index ["conversation_id", "contact_id"], name: "idx_conv_participants_on_conv_and_contact", unique: true, where: "contact_id IS NOT NULL"
    t.index ["conversation_id", "user_id"], name: "idx_conv_participants_on_conv_and_user", unique: true, where: "user_id IS NOT NULL"
    t.index ["conversation_id"], name: "index_conversation_participants_on_conversation_id"
    t.index ["user_id"], name: "index_conversation_participants_on_user_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.string "counterparty_pubkey"
    t.datetime "created_at", null: false
    t.integer "kind", default: 0, null: false
    t.string "name"
    t.string "public_id", limit: 12, null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_conversations_on_public_id", unique: true
  end

  create_table "csam_hash_entries", force: :cascade do |t|
    t.datetime "added_at"
    t.datetime "created_at", null: false
    t.string "hash_type", null: false
    t.string "hash_value", null: false
    t.string "list_source"
    t.datetime "updated_at", null: false
    t.index ["hash_value", "hash_type"], name: "index_csam_hash_entries_on_hash_value_and_hash_type", unique: true
    t.index ["list_source"], name: "index_csam_hash_entries_on_list_source"
  end

  create_table "data_exports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "export_type", default: "full", null: false
    t.string "file_path"
    t.bigint "requested_by_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["requested_by_id"], name: "index_data_exports_on_requested_by_id"
    t.index ["status"], name: "index_data_exports_on_status"
    t.index ["user_id"], name: "index_data_exports_on_user_id"
  end

  create_table "domain_block_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "instance_blocklist_id", null: false
    t.json "snapshot_data", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["instance_blocklist_id"], name: "index_domain_block_snapshots_on_instance_blocklist_id", unique: true
  end

  create_table "federation_audit_logs", force: :cascade do |t|
    t.bigint "actor_id"
    t.string "actor_type"
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.string "ip_address"
    t.json "metadata", default: {}
    t.string "remote_domain"
    t.bigint "target_id"
    t.string "target_type"
    t.index ["actor_type", "actor_id"], name: "index_federation_audit_logs_on_actor_type_and_actor_id"
    t.index ["event_type", "created_at"], name: "index_federation_audit_logs_on_event_type_and_created_at"
    t.index ["remote_domain", "created_at"], name: "index_federation_audit_logs_on_remote_domain_and_created_at"
    t.index ["target_type", "target_id"], name: "index_federation_audit_logs_on_target_type_and_target_id"
  end

  create_table "friendships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "federation_callback_token"
    t.bigint "friend_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["friend_id"], name: "index_friendships_on_friend_id"
    t.index ["user_id", "friend_id"], name: "index_friendships_on_user_id_and_friend_id", unique: true
    t.index ["user_id"], name: "index_friendships_on_user_id"
  end

  create_table "gif_collections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "icon", limit: 255
    t.string "name", limit: 50, null: false
    t.integer "position", default: 0
    t.string "public_id", limit: 12, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["public_id"], name: "index_gif_collections_on_public_id", unique: true
    t.index ["user_id", "name"], name: "index_gif_collections_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_gif_collections_on_user_id"
  end

  create_table "gif_favorites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description", limit: 100
    t.bigint "gif_collection_id", null: false
    t.string "gif_url", null: false
    t.integer "position", default: 0
    t.string "preview_url", null: false
    t.string "public_id", limit: 12, null: false
    t.string "tenor_gif_id", null: false
    t.string "tenor_url", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["gif_collection_id"], name: "index_gif_favorites_on_gif_collection_id"
    t.index ["public_id"], name: "index_gif_favorites_on_public_id", unique: true
    t.index ["user_id", "gif_collection_id", "tenor_gif_id"], name: "index_gif_favorites_on_user_collection_tenor", unique: true
    t.index ["user_id"], name: "index_gif_favorites_on_user_id"
  end

  create_table "hidden_attachment_records", force: :cascade do |t|
    t.bigint "byte_size"
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.integer "message_id", null: false
    t.string "original_filename", null: false
    t.datetime "purged_at", null: false
    t.integer "purged_by_id", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_hidden_attachment_records_on_message_id"
    t.index ["purged_by_id"], name: "index_hidden_attachment_records_on_purged_by_id"
  end

  create_table "instance_blocklists", force: :cascade do |t|
    t.datetime "blocked_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.bigint "blocked_by_id", null: false
    t.datetime "created_at", null: false
    t.string "domain", null: false
    t.text "reason"
    t.datetime "updated_at", null: false
    t.index ["blocked_by_id"], name: "index_instance_blocklists_on_blocked_by_id"
    t.index ["domain"], name: "index_instance_blocklists_on_domain", unique: true
  end

  create_table "instance_configs", force: :cascade do |t|
    t.integer "attachment_retention_days", default: 0
    t.integer "backfill_days", default: 30
    t.boolean "backfill_enabled", default: true
    t.json "blossom_server_urls"
    t.datetime "created_at", null: false
    t.string "federation_mode", default: "open", null: false
    t.text "instance_description"
    t.string "instance_name", default: "Inferno Chat"
    t.string "instance_relay_url"
    t.boolean "keep_pinned_messages", default: true
    t.string "livekit_api_key"
    t.text "livekit_api_secret_enc"
    t.string "livekit_url"
    t.boolean "livekit_verified", default: false
    t.datetime "livekit_verified_at"
    t.boolean "lockdown_enabled", default: false, null: false
    t.boolean "lockdown_invite_creation", default: false, null: false
    t.boolean "lockdown_local_signups", default: false, null: false
    t.boolean "lockdown_remote_auth", default: false, null: false
    t.boolean "lockdown_remote_joins", default: false, null: false
    t.integer "max_cache_size_mb", default: 500
    t.integer "max_categories_per_server", default: 20
    t.integer "max_channels_per_server", default: 50
    t.integer "max_db_size_mb", default: 0
    t.integer "max_members_per_server", default: 0
    t.integer "max_roles_per_server", default: 25
    t.integer "max_servers", default: 0
    t.integer "max_servers_per_user", default: 5
    t.integer "max_storage_per_user_mb", default: 0
    t.integer "max_upload_size_mb", default: 25
    t.integer "max_users", default: 0
    t.integer "max_voice_participants_per_channel", default: 25
    t.integer "message_retention_days", default: 0
    t.boolean "prune_channel_messages", default: true
    t.boolean "prune_dm_messages", default: true
    t.string "pruning_strategy", default: "none"
    t.boolean "safety_block_all_caps", default: false
    t.boolean "safety_block_links", default: false
    t.boolean "safety_block_phone_numbers", default: false
    t.boolean "safety_block_spam_chars", default: false
    t.boolean "safety_blur_nsfw", default: true
    t.boolean "safety_hide_unknown_senders", default: false
    t.boolean "safety_image_hash_enabled", default: false
    t.text "safety_keyword_filter", default: ""
    t.string "safety_protection_level", default: "standard"
    t.boolean "safety_publish_hashes", default: true
    t.integer "safety_report_threshold", default: 0
    t.boolean "safety_reputation_enabled", default: false
    t.string "safety_reputation_sensitivity", default: "moderate"
    t.integer "safety_reputation_threshold", default: 30
    t.integer "safety_shared_hash_min_reporters", default: 3
    t.boolean "safety_shared_hash_trust_friends", default: true
    t.boolean "safety_shared_hashes_enabled", default: false
    t.datetime "updated_at", null: false
    t.boolean "voice_enabled", default: false, null: false
  end

  create_table "invites", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.bigint "creator_id", null: false
    t.datetime "expires_at"
    t.integer "max_uses"
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.integer "uses_count", default: 0, null: false
    t.index ["code"], name: "index_invites_on_code", unique: true
    t.index ["creator_id"], name: "index_invites_on_creator_id"
    t.index ["server_id", "active"], name: "index_invites_on_server_id_and_active"
    t.index ["server_id"], name: "index_invites_on_server_id"
  end

  create_table "legal_holds", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "holdable_id", null: false
    t.string "holdable_type", null: false
    t.datetime "lifted_at"
    t.datetime "placed_at", null: false
    t.bigint "placed_by_id", null: false
    t.text "reason"
    t.datetime "updated_at", null: false
    t.index ["holdable_type", "holdable_id"], name: "index_legal_holds_active_unique", unique: true, where: "(active = true)"
    t.index ["holdable_type", "holdable_id"], name: "index_legal_holds_on_holdable_type_and_holdable_id"
    t.index ["placed_by_id"], name: "index_legal_holds_on_placed_by_id"
  end

  create_table "membership_roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "role_id", null: false
    t.bigint "server_membership_id", null: false
    t.datetime "updated_at", null: false
    t.index ["role_id"], name: "index_membership_roles_on_role_id"
    t.index ["server_membership_id", "role_id"], name: "index_membership_roles_on_server_membership_id_and_role_id", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "channel_id"
    t.text "content"
    t.bigint "conversation_id"
    t.datetime "created_at", null: false
    t.datetime "edited_at"
    t.datetime "hidden_at"
    t.bigint "hidden_by_id"
    t.string "hidden_reason"
    t.boolean "is_sticker", default: false, null: false
    t.string "nostr_author_pubkey"
    t.string "nostr_event_id"
    t.text "nostr_event_json"
    t.bigint "parent_id"
    t.boolean "pinned"
    t.string "public_id", limit: 12, null: false
    t.text "rendered_content_cached"
    t.boolean "spoiler", default: false, null: false
    t.boolean "system_message", default: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["channel_id", "created_at"], name: "index_messages_on_channel_id_and_created_at"
    t.index ["channel_id"], name: "index_messages_on_channel_id"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["hidden_at"], name: "index_messages_on_hidden_at", where: "hidden_at IS NOT NULL"
    t.index ["nostr_event_id"], name: "index_messages_on_nostr_event_id", unique: true
    t.index ["parent_id"], name: "index_messages_on_parent_id"
    t.index ["public_id"], name: "index_messages_on_public_id", unique: true
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "moderation_reports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "reason"
    t.string "report_type", null: false
    t.string "reported_event_id"
    t.string "reported_pubkey", null: false
    t.bigint "reporter_id", null: false
    t.bigint "reviewed_by_id"
    t.string "status", default: "open", null: false
    t.datetime "updated_at", null: false
    t.index ["reported_pubkey"], name: "index_moderation_reports_on_reported_pubkey"
    t.index ["reporter_id"], name: "index_moderation_reports_on_reporter_id"
    t.index ["reviewed_by_id"], name: "index_moderation_reports_on_reviewed_by_id"
    t.index ["status"], name: "index_moderation_reports_on_status"
  end

  create_table "nip05_caches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "identifier", null: false
    t.string "public_key", null: false
    t.datetime "updated_at", null: false
    t.datetime "verified_at", null: false
    t.index ["identifier"], name: "index_nip05_caches_on_identifier", unique: true
    t.index ["public_key"], name: "index_nip05_caches_on_public_key"
  end

  create_table "nostr_auth_challenges", force: :cascade do |t|
    t.string "callback_url", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "nonce", null: false
    t.string "requesting_domain", null: false
    t.datetime "updated_at", null: false
    t.boolean "used", default: false
    t.index ["nonce"], name: "index_nostr_auth_challenges_on_nonce", unique: true
  end

  create_table "nostr_event_logs", force: :cascade do |t|
    t.bigint "channel_id"
    t.datetime "created_at", null: false
    t.string "direction", null: false
    t.datetime "event_created_at"
    t.string "event_id", null: false
    t.integer "kind", null: false
    t.bigint "message_id"
    t.string "pubkey", null: false
    t.integer "server_id"
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_nostr_event_logs_on_channel_id"
    t.index ["event_id"], name: "index_nostr_event_logs_on_event_id", unique: true
    t.index ["message_id"], name: "index_nostr_event_logs_on_message_id"
    t.index ["server_id"], name: "index_nostr_event_logs_on_server_id"
  end

  create_table "nostr_events", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "event_created_at", null: false
    t.string "event_id", null: false
    t.integer "kind", null: false
    t.string "pubkey", null: false
    t.string "sig", null: false
    t.json "tags"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_nostr_events_on_event_id", unique: true
    t.index ["kind", "pubkey"], name: "index_nostr_events_on_kind_and_pubkey"
    t.index ["kind"], name: "index_nostr_events_on_kind"
    t.index ["pubkey"], name: "index_nostr_events_on_pubkey"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "channel_id", null: false
    t.datetime "created_at", null: false
    t.bigint "message_id", null: false
    t.integer "notification_type", default: 0, null: false
    t.boolean "read", default: false, null: false
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["channel_id"], name: "index_notifications_on_channel_id"
    t.index ["message_id"], name: "index_notifications_on_message_id"
    t.index ["server_id"], name: "index_notifications_on_server_id"
    t.index ["user_id", "channel_id", "read"], name: "index_notifications_on_user_id_and_channel_id_and_read"
    t.index ["user_id", "read"], name: "index_notifications_on_user_id_and_read"
    t.index ["user_id", "server_id", "read"], name: "index_notifications_on_user_id_and_server_id_and_read"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "reactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "emoji"
    t.bigint "message_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["message_id"], name: "index_reactions_on_message_id"
    t.index ["user_id", "message_id", "emoji"], name: "index_reactions_on_user_id_and_message_id_and_emoji", unique: true
    t.index ["user_id"], name: "index_reactions_on_user_id"
  end

  create_table "relay_connections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_connected_at"
    t.datetime "last_error_at"
    t.text "last_error_message"
    t.integer "retry_count", default: 0
    t.string "status", default: "active"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["url"], name: "index_relay_connections_on_url", unique: true
  end

  create_table "remote_conversation_references", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kind", default: "direct"
    t.datetime "last_message_at"
    t.string "name"
    t.string "other_avatar_url"
    t.string "other_display_name"
    t.string "other_profile_color"
    t.string "other_username"
    t.string "remote_conversation_id", null: false
    t.string "remote_instance_url", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "remote_instance_url", "remote_conversation_id"], name: "idx_remote_conv_refs_unique", unique: true
    t.index ["user_id"], name: "index_remote_conversation_references_on_user_id"
  end

  create_table "remote_friend_references", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "friend_avatar_url"
    t.string "friend_discriminator"
    t.string "friend_display_name"
    t.string "friend_profile_color"
    t.string "friend_public_key"
    t.string "friend_username"
    t.string "online_state", default: "offline"
    t.string "remote_instance_url", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "remote_instance_url", "friend_public_key"], name: "idx_remote_friends_unique", unique: true
    t.index ["user_id"], name: "index_remote_friend_references_on_user_id"
  end

  create_table "remote_members", force: :cascade do |t|
    t.string "avatar_url"
    t.string "banner_url"
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.datetime "joined_at"
    t.datetime "last_seen_at"
    t.string "nickname"
    t.string "nip05"
    t.integer "online_state", default: 0, null: false
    t.string "profile_color"
    t.string "profile_color_2"
    t.datetime "profile_fetched_at"
    t.string "pubkey", null: false
    t.string "public_id"
    t.integer "report_count", default: 0, null: false
    t.integer "server_id", null: false
    t.string "status"
    t.string "status_emoji"
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["public_id"], name: "index_remote_members_on_public_id", unique: true
    t.index ["server_id", "pubkey"], name: "index_remote_members_on_server_id_and_pubkey", unique: true
    t.index ["server_id"], name: "index_remote_members_on_server_id"
  end

  create_table "remote_membership_roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "remote_member_id", null: false
    t.integer "role_id", null: false
    t.datetime "updated_at", null: false
    t.index ["remote_member_id", "role_id"], name: "index_remote_membership_roles_on_remote_member_id_and_role_id", unique: true
    t.index ["remote_member_id"], name: "index_remote_membership_roles_on_remote_member_id"
    t.index ["role_id"], name: "index_remote_membership_roles_on_role_id"
  end

  create_table "remote_server_references", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "icon_url"
    t.string "invite_code"
    t.string "name"
    t.integer "position", default: 0
    t.string "remote_instance_url", null: false
    t.string "remote_server_id", null: false
    t.bigint "server_folder_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["server_folder_id"], name: "index_remote_server_references_on_server_folder_id"
    t.index ["user_id", "remote_instance_url", "remote_server_id"], name: "idx_remote_server_refs_unique", unique: true
    t.index ["user_id"], name: "index_remote_server_references_on_user_id"
  end

  create_table "remote_users", force: :cascade do |t|
    t.string "avatar_url"
    t.integer "banner_offset_y"
    t.string "banner_url"
    t.text "bio"
    t.datetime "created_at", null: false
    t.string "discriminator", limit: 4
    t.string "display_name"
    t.text "federation_token"
    t.string "home_instance", null: false
    t.datetime "last_profile_sync_at"
    t.datetime "last_verified_at"
    t.string "nostr_public_key", null: false
    t.string "profile_color"
    t.string "profile_color_2"
    t.string "public_id", limit: 12
    t.string "status"
    t.string "status_emoji"
    t.datetime "updated_at", null: false
    t.string "username"
    t.index ["home_instance"], name: "index_remote_users_on_home_instance"
    t.index ["nostr_public_key"], name: "index_remote_users_on_nostr_public_key", unique: true
    t.index ["public_id"], name: "index_remote_users_on_public_id", unique: true
  end

  create_table "roles", force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.boolean "hoist", default: false, null: false
    t.boolean "mentionable"
    t.string "name"
    t.json "permissions"
    t.integer "position"
    t.string "public_id", limit: 12, null: false
    t.string "role_type"
    t.boolean "self_assignable", default: false, null: false
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_roles_on_public_id", unique: true
    t.index ["server_id"], name: "index_roles_on_server_id"
  end

  create_table "server_emojis", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id", null: false
    t.string "name", limit: 32, null: false
    t.string "public_id", limit: 12, null: false
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_server_emojis_on_creator_id"
    t.index ["public_id"], name: "index_server_emojis_on_public_id", unique: true
    t.index ["server_id", "name"], name: "index_server_emojis_on_server_id_and_name", unique: true
    t.index ["server_id"], name: "index_server_emojis_on_server_id"
  end

  create_table "server_folders", force: :cascade do |t|
    t.boolean "collapsed", default: true, null: false
    t.string "color", limit: 7, default: "#4f545c"
    t.datetime "created_at", null: false
    t.string "name", limit: 50, default: "Folder", null: false
    t.integer "position", default: 0, null: false
    t.string "public_id", limit: 12, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["public_id"], name: "index_server_folders_on_public_id", unique: true
    t.index ["user_id", "position"], name: "index_server_folders_on_user_id_and_position"
    t.index ["user_id"], name: "index_server_folders_on_user_id"
  end

  create_table "server_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "joined_at"
    t.string "nickname"
    t.boolean "onboarding_completed", default: false, null: false
    t.integer "position", default: 0, null: false
    t.string "public_id", limit: 12, null: false
    t.bigint "server_folder_id"
    t.bigint "server_id", null: false
    t.bigint "timed_out_by_id"
    t.datetime "timed_out_until"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["public_id"], name: "index_server_memberships_on_public_id", unique: true
    t.index ["server_folder_id"], name: "index_server_memberships_on_server_folder_id"
    t.index ["server_id"], name: "index_server_memberships_on_server_id"
    t.index ["user_id", "server_id"], name: "index_server_memberships_on_user_id_and_server_id", unique: true
    t.index ["user_id"], name: "index_server_memberships_on_user_id"
  end

  create_table "server_stickers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id", null: false
    t.string "description", limit: 100
    t.string "name", limit: 50, null: false
    t.string "public_id", limit: 12, null: false
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_server_stickers_on_creator_id"
    t.index ["public_id"], name: "index_server_stickers_on_public_id", unique: true
    t.index ["server_id", "name"], name: "index_server_stickers_on_server_id_and_name", unique: true
    t.index ["server_id"], name: "index_server_stickers_on_server_id"
  end

  create_table "server_voice_providers", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "position", default: 0, null: false
    t.string "provider_pubkey"
    t.integer "server_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["server_id", "provider_pubkey"], name: "idx_svp_on_server_id_and_provider_pubkey", unique: true
    t.index ["server_id", "user_id"], name: "index_server_voice_providers_on_server_id_and_user_id", unique: true
    t.index ["server_id"], name: "index_server_voice_providers_on_server_id"
    t.index ["user_id"], name: "index_server_voice_providers_on_user_id"
  end

  create_table "servers", force: :cascade do |t|
    t.string "afk_action", default: "move", null: false
    t.integer "afk_channel_id"
    t.integer "afk_timeout", default: 5, null: false
    t.boolean "age_restricted", default: false
    t.boolean "banner_nsfw", default: false, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.boolean "discoverable", default: false, null: false
    t.boolean "icon_nsfw", default: false, null: false
    t.string "invite_code"
    t.string "name"
    t.string "nostr_group_id"
    t.json "onboarding_default_channel_ids", default: []
    t.boolean "onboarding_enabled", default: false, null: false
    t.text "onboarding_rules"
    t.json "onboarding_self_assignable_role_ids", default: []
    t.bigint "owner_id", null: false
    t.string "public_id", limit: 12, null: false
    t.json "relay_urls"
    t.json "remote_owner_pubkeys", default: []
    t.string "server_type", default: "community"
    t.datetime "updated_at", null: false
    t.boolean "voice_enabled", default: false
    t.bigint "welcome_channel_id"
    t.boolean "welcome_message_enabled", default: true
    t.text "welcome_message_template", default: "Welcome to the server, {user}! 🎉"
    t.index ["afk_channel_id"], name: "index_servers_on_afk_channel_id"
    t.index ["invite_code"], name: "index_servers_on_invite_code", unique: true
    t.index ["owner_id"], name: "index_servers_on_owner_id"
    t.index ["public_id"], name: "index_servers_on_public_id", unique: true
    t.index ["welcome_channel_id"], name: "index_servers_on_welcome_channel_id"
  end

  create_table "user_suspensions", force: :cascade do |t|
    t.boolean "auto_triggered", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "federation_broadcast_at"
    t.string "federation_broadcast_status", default: "not_applicable", null: false
    t.text "lift_reason"
    t.datetime "lifted_at"
    t.bigint "lifted_by_id"
    t.text "reason"
    t.string "reason_category"
    t.bigint "suspended_by_id"
    t.string "suspension_type", null: false
    t.bigint "triggered_by_quarantine_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["created_at"], name: "index_user_suspensions_on_created_at"
    t.index ["expires_at"], name: "index_user_suspensions_on_expires_at_active", where: "(lifted_at IS NULL)"
    t.index ["lifted_by_id"], name: "index_user_suspensions_on_lifted_by_id"
    t.index ["reason_category"], name: "index_user_suspensions_on_reason_category"
    t.index ["suspended_by_id"], name: "index_user_suspensions_on_suspended_by_id"
    t.index ["suspension_type"], name: "index_user_suspensions_on_suspension_type"
    t.index ["user_id", "lifted_at"], name: "index_user_suspensions_on_user_id_and_lifted_at"
    t.index ["user_id"], name: "index_user_suspensions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "avatar_nsfw", default: false, null: false
    t.boolean "banner_nsfw", default: false, null: false
    t.integer "banner_offset_y"
    t.text "bio"
    t.datetime "confirmation_sent_at"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.datetime "custom_status_expires_at"
    t.string "discriminator", limit: 4, default: "0000", null: false
    t.string "display_name"
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.boolean "instance_admin", default: false, null: false
    t.string "livekit_api_key"
    t.text "livekit_api_secret_enc"
    t.string "livekit_url"
    t.boolean "livekit_verified", default: false
    t.datetime "livekit_verified_at"
    t.datetime "nostr_contacts_published_at"
    t.text "nostr_encrypted_private_key"
    t.datetime "nostr_profile_published_at"
    t.string "nostr_public_key"
    t.datetime "online_at"
    t.integer "online_state", default: 0, null: false
    t.string "profile_color"
    t.string "profile_color_2"
    t.string "public_id", limit: 12, null: false
    t.datetime "remember_created_at"
    t.boolean "remote", default: false, null: false
    t.bigint "remote_user_detail_id"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.string "status"
    t.string "status_emoji"
    t.datetime "suspended_at"
    t.string "theme", default: "inferno", null: false
    t.string "unconfirmed_email"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.json "voice_settings", default: {}, null: false
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["nostr_public_key"], name: "index_users_on_nostr_public_key", unique: true
    t.index ["public_id"], name: "index_users_on_public_id", unique: true
    t.index ["remote_user_detail_id"], name: "index_users_on_remote_user_detail_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["username", "discriminator"], name: "index_users_on_username_and_discriminator", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.datetime "created_at"
    t.string "event", null: false
    t.string "ip_address"
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.json "metadata"
    t.text "object"
    t.string "remote_domain"
    t.string "whodunnit"
    t.index ["created_at"], name: "index_versions_on_created_at"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
    t.index ["remote_domain"], name: "index_versions_on_remote_domain", where: "(remote_domain IS NOT NULL)"
  end

  create_table "voice_showcases", force: :cascade do |t|
    t.integer "approved_by_id"
    t.integer "child_channel_id", null: false
    t.datetime "created_at", null: false
    t.integer "parent_channel_id", null: false
    t.string "public_id"
    t.integer "server_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["approved_by_id"], name: "index_voice_showcases_on_approved_by_id"
    t.index ["child_channel_id"], name: "index_voice_showcases_on_child_channel_id"
    t.index ["parent_channel_id"], name: "index_voice_showcases_on_parent_channel_id"
    t.index ["public_id"], name: "index_voice_showcases_on_public_id", unique: true
    t.index ["server_id"], name: "index_voice_showcases_on_server_id"
    t.index ["user_id"], name: "index_voice_showcases_on_user_id"
  end

  create_table "voice_states", force: :cascade do |t|
    t.boolean "broadcasting", default: false, null: false
    t.bigint "channel_id", null: false
    t.datetime "created_at", null: false
    t.string "public_id", limit: 12, null: false
    t.boolean "screen_share_on", default: false, null: false
    t.boolean "self_deaf", default: false, null: false
    t.boolean "self_mute", default: false, null: false
    t.boolean "server_deaf", default: false, null: false
    t.bigint "server_id", null: false
    t.boolean "server_mute", default: false, null: false
    t.string "session_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.boolean "video_on", default: false, null: false
    t.index ["channel_id"], name: "index_voice_states_on_channel_id"
    t.index ["public_id"], name: "index_voice_states_on_public_id", unique: true
    t.index ["server_id"], name: "index_voice_states_on_server_id"
    t.index ["session_id"], name: "index_voice_states_on_session_id", unique: true
    t.index ["user_id", "server_id"], name: "index_voice_states_on_user_id_and_server_id", unique: true
    t.index ["user_id"], name: "index_voice_states_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "bans", "servers"
  add_foreign_key "bans", "users"
  add_foreign_key "bans", "users", column: "banned_by_id"
  add_foreign_key "blocks", "users", column: "blocked_id"
  add_foreign_key "blocks", "users", column: "blocker_id"
  add_foreign_key "call_participants", "calls"
  add_foreign_key "call_participants", "users"
  add_foreign_key "calls", "conversations"
  add_foreign_key "calls", "users", column: "initiated_by_id"
  add_foreign_key "categories", "servers"
  add_foreign_key "channel_reads", "channels"
  add_foreign_key "channel_reads", "users"
  add_foreign_key "channels", "categories"
  add_foreign_key "channels", "channels", column: "parent_channel_id", on_delete: :cascade
  add_foreign_key "channels", "channels", column: "sidechat_channel_id"
  add_foreign_key "channels", "servers"
  add_foreign_key "channels", "users", column: "current_voice_provider_id"
  add_foreign_key "content_hashes", "messages"
  add_foreign_key "conversation_participants", "contacts"
  add_foreign_key "conversation_participants", "conversations"
  add_foreign_key "conversation_participants", "users"
  add_foreign_key "data_exports", "users"
  add_foreign_key "data_exports", "users", column: "requested_by_id"
  add_foreign_key "domain_block_snapshots", "instance_blocklists"
  add_foreign_key "friendships", "users"
  add_foreign_key "friendships", "users", column: "friend_id"
  add_foreign_key "gif_collections", "users"
  add_foreign_key "gif_favorites", "gif_collections"
  add_foreign_key "gif_favorites", "users"
  add_foreign_key "hidden_attachment_records", "messages"
  add_foreign_key "hidden_attachment_records", "users", column: "purged_by_id"
  add_foreign_key "instance_blocklists", "users", column: "blocked_by_id"
  add_foreign_key "invites", "servers"
  add_foreign_key "invites", "users", column: "creator_id"
  add_foreign_key "legal_holds", "users", column: "placed_by_id"
  add_foreign_key "membership_roles", "roles"
  add_foreign_key "membership_roles", "server_memberships"
  add_foreign_key "messages", "channels"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "messages", column: "parent_id"
  add_foreign_key "messages", "users"
  add_foreign_key "messages", "users", column: "hidden_by_id"
  add_foreign_key "moderation_reports", "users", column: "reporter_id"
  add_foreign_key "moderation_reports", "users", column: "reviewed_by_id"
  add_foreign_key "nostr_event_logs", "channels"
  add_foreign_key "nostr_event_logs", "messages"
  add_foreign_key "nostr_event_logs", "servers"
  add_foreign_key "notifications", "channels"
  add_foreign_key "notifications", "messages"
  add_foreign_key "notifications", "servers"
  add_foreign_key "notifications", "users"
  add_foreign_key "reactions", "messages"
  add_foreign_key "reactions", "users"
  add_foreign_key "remote_conversation_references", "users"
  add_foreign_key "remote_friend_references", "users"
  add_foreign_key "remote_members", "servers"
  add_foreign_key "remote_membership_roles", "remote_members"
  add_foreign_key "remote_membership_roles", "roles"
  add_foreign_key "remote_server_references", "server_folders"
  add_foreign_key "remote_server_references", "users"
  add_foreign_key "roles", "servers"
  add_foreign_key "server_emojis", "servers"
  add_foreign_key "server_emojis", "users", column: "creator_id"
  add_foreign_key "server_folders", "users"
  add_foreign_key "server_memberships", "server_folders"
  add_foreign_key "server_memberships", "servers"
  add_foreign_key "server_memberships", "users"
  add_foreign_key "server_stickers", "servers"
  add_foreign_key "server_stickers", "users", column: "creator_id"
  add_foreign_key "server_voice_providers", "servers"
  add_foreign_key "server_voice_providers", "users", on_delete: :nullify
  add_foreign_key "servers", "channels", column: "afk_channel_id", on_delete: :nullify
  add_foreign_key "servers", "channels", column: "welcome_channel_id", on_delete: :nullify
  add_foreign_key "servers", "users", column: "owner_id"
  add_foreign_key "user_suspensions", "users"
  add_foreign_key "user_suspensions", "users", column: "lifted_by_id"
  add_foreign_key "user_suspensions", "users", column: "suspended_by_id"
  add_foreign_key "users", "remote_users", column: "remote_user_detail_id"
  add_foreign_key "voice_showcases", "channels", column: "child_channel_id"
  add_foreign_key "voice_showcases", "channels", column: "parent_channel_id"
  add_foreign_key "voice_showcases", "servers"
  add_foreign_key "voice_showcases", "users"
  add_foreign_key "voice_showcases", "users", column: "approved_by_id"
  add_foreign_key "voice_states", "channels"
  add_foreign_key "voice_states", "servers"
  add_foreign_key "voice_states", "users"
end
