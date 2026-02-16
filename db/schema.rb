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

ActiveRecord::Schema[8.0].define(version: 2026_02_15_110002) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "bans", force: :cascade do |t|
    t.bigint "server_id", null: false
    t.bigint "user_id", null: false
    t.bigint "banned_by_id", null: false
    t.text "reason"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["banned_by_id"], name: "index_bans_on_banned_by_id"
    t.index ["server_id", "user_id"], name: "index_bans_on_server_id_and_user_id", unique: true
    t.index ["server_id"], name: "index_bans_on_server_id"
    t.index ["user_id"], name: "index_bans_on_user_id"
  end

  create_table "blocks", force: :cascade do |t|
    t.bigint "blocker_id", null: false
    t.bigint "blocked_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blocked_id"], name: "index_blocks_on_blocked_id"
    t.index ["blocker_id", "blocked_id"], name: "index_blocks_on_blocker_id_and_blocked_id", unique: true
    t.index ["blocker_id"], name: "index_blocks_on_blocker_id"
  end

  create_table "categories", force: :cascade do |t|
    t.string "name"
    t.integer "position"
    t.bigint "server_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "public_id", limit: 12, null: false
    t.index ["public_id"], name: "index_categories_on_public_id", unique: true
    t.index ["server_id"], name: "index_categories_on_server_id"
  end

  create_table "channel_reads", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "channel_id", null: false
    t.datetime "last_read_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_channel_reads_on_channel_id"
    t.index ["user_id", "channel_id"], name: "index_channel_reads_on_user_id_and_channel_id", unique: true
    t.index ["user_id"], name: "index_channel_reads_on_user_id"
  end

  create_table "channels", force: :cascade do |t|
    t.string "name"
    t.text "topic"
    t.integer "position"
    t.integer "channel_type"
    t.boolean "nsfw"
    t.jsonb "permissions_overrides"
    t.bigint "server_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "category_id"
    t.string "public_id", limit: 12, null: false
    t.boolean "shared", default: false
    t.string "nostr_group_id"
    t.string "nostr_relay_url"
    t.index ["category_id"], name: "index_channels_on_category_id"
    t.index ["nostr_group_id"], name: "index_channels_on_nostr_group_id"
    t.index ["public_id"], name: "index_channels_on_public_id", unique: true
    t.index ["server_id"], name: "index_channels_on_server_id"
  end

  create_table "conversation_participants", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.bigint "user_id", null: false
    t.boolean "accepted", default: false, null: false
    t.boolean "muted", default: false, null: false
    t.datetime "last_read_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "user_id"], name: "index_conversation_participants_on_conversation_id_and_user_id", unique: true
    t.index ["conversation_id"], name: "index_conversation_participants_on_conversation_id"
    t.index ["user_id"], name: "index_conversation_participants_on_user_id"
  end

  create_table "conversations", force: :cascade do |t|
    t.integer "kind", default: 0, null: false
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "public_id", limit: 12, null: false
    t.index ["public_id"], name: "index_conversations_on_public_id", unique: true
  end

  create_table "friendships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "friend_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["friend_id"], name: "index_friendships_on_friend_id"
    t.index ["user_id", "friend_id"], name: "index_friendships_on_user_id_and_friend_id", unique: true
    t.index ["user_id"], name: "index_friendships_on_user_id"
  end

  create_table "gif_collections", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", limit: 50, null: false
    t.integer "position", default: 0
    t.string "public_id", limit: 12, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "icon", limit: 255
    t.index ["public_id"], name: "index_gif_collections_on_public_id", unique: true
    t.index ["user_id", "name"], name: "index_gif_collections_on_user_id_and_name", unique: true
    t.index ["user_id"], name: "index_gif_collections_on_user_id"
  end

  create_table "gif_favorites", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "gif_collection_id", null: false
    t.string "tenor_gif_id", null: false
    t.string "tenor_url", null: false
    t.string "preview_url", null: false
    t.string "gif_url", null: false
    t.string "description", limit: 100
    t.integer "position", default: 0
    t.string "public_id", limit: 12, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["gif_collection_id"], name: "index_gif_favorites_on_gif_collection_id"
    t.index ["public_id"], name: "index_gif_favorites_on_public_id", unique: true
    t.index ["user_id", "gif_collection_id", "tenor_gif_id"], name: "index_gif_favorites_on_user_collection_tenor", unique: true
    t.index ["user_id"], name: "index_gif_favorites_on_user_id"
  end

  create_table "instance_blocklists", force: :cascade do |t|
    t.string "domain", null: false
    t.text "reason"
    t.bigint "blocked_by_id", null: false
    t.datetime "blocked_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blocked_by_id"], name: "index_instance_blocklists_on_blocked_by_id"
    t.index ["domain"], name: "index_instance_blocklists_on_domain", unique: true
  end

  create_table "instance_configs", force: :cascade do |t|
    t.string "instance_name", default: "Inferno Chat"
    t.text "instance_description"
    t.integer "max_users", default: 0
    t.integer "max_servers_per_user", default: 5
    t.integer "max_servers", default: 0
    t.integer "max_channels_per_server", default: 50
    t.integer "max_categories_per_server", default: 20
    t.integer "max_members_per_server", default: 0
    t.integer "max_roles_per_server", default: 25
    t.integer "max_upload_size_mb", default: 25
    t.integer "max_storage_per_user_mb", default: 0
    t.string "pruning_strategy", default: "none"
    t.integer "message_retention_days", default: 0
    t.integer "attachment_retention_days", default: 0
    t.boolean "keep_pinned_messages", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "federation_mode", default: "open", null: false
    t.boolean "lockdown_enabled", default: false, null: false
    t.string "instance_relay_url"
    t.boolean "lockdown_remote_auth", default: false, null: false
    t.boolean "lockdown_remote_joins", default: false, null: false
    t.boolean "lockdown_local_signups", default: false, null: false
    t.boolean "lockdown_invite_creation", default: false, null: false
  end

  create_table "invites", force: :cascade do |t|
    t.string "code", null: false
    t.bigint "server_id", null: false
    t.bigint "creator_id", null: false
    t.integer "max_uses"
    t.integer "uses_count", default: 0, null: false
    t.datetime "expires_at"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_invites_on_code", unique: true
    t.index ["creator_id"], name: "index_invites_on_creator_id"
    t.index ["server_id", "active"], name: "index_invites_on_server_id_and_active"
    t.index ["server_id"], name: "index_invites_on_server_id"
  end

  create_table "membership_roles", force: :cascade do |t|
    t.bigint "server_membership_id", null: false
    t.bigint "role_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["role_id"], name: "index_membership_roles_on_role_id"
    t.index ["server_membership_id", "role_id"], name: "index_membership_roles_on_server_membership_id_and_role_id", unique: true
  end

  create_table "messages", force: :cascade do |t|
    t.text "content"
    t.datetime "edited_at"
    t.boolean "pinned"
    t.bigint "user_id", null: false
    t.bigint "channel_id"
    t.bigint "parent_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "system_message", default: false
    t.bigint "conversation_id"
    t.text "rendered_content_cached"
    t.string "public_id", limit: 12, null: false
    t.index ["channel_id", "created_at"], name: "index_messages_on_channel_id_and_created_at"
    t.index ["channel_id"], name: "index_messages_on_channel_id"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["parent_id"], name: "index_messages_on_parent_id"
    t.index ["public_id"], name: "index_messages_on_public_id", unique: true
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "moderation_reports", force: :cascade do |t|
    t.bigint "reporter_id", null: false
    t.string "reported_pubkey", null: false
    t.string "reported_event_id"
    t.string "report_type", null: false
    t.text "reason"
    t.string "status", default: "open", null: false
    t.bigint "reviewed_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["reported_pubkey"], name: "index_moderation_reports_on_reported_pubkey"
    t.index ["reporter_id"], name: "index_moderation_reports_on_reporter_id"
    t.index ["reviewed_by_id"], name: "index_moderation_reports_on_reviewed_by_id"
    t.index ["status"], name: "index_moderation_reports_on_status"
  end

  create_table "nip05_caches", force: :cascade do |t|
    t.string "identifier", null: false
    t.string "public_key", null: false
    t.datetime "verified_at", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["identifier"], name: "index_nip05_caches_on_identifier", unique: true
    t.index ["public_key"], name: "index_nip05_caches_on_public_key"
  end

  create_table "nostr_auth_challenges", force: :cascade do |t|
    t.string "nonce", null: false
    t.string "requesting_domain", null: false
    t.string "callback_url", null: false
    t.datetime "expires_at", null: false
    t.boolean "used", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["nonce"], name: "index_nostr_auth_challenges_on_nonce", unique: true
  end

  create_table "nostr_event_logs", force: :cascade do |t|
    t.string "event_id", null: false
    t.integer "kind", null: false
    t.string "pubkey", null: false
    t.bigint "message_id"
    t.bigint "channel_id"
    t.string "direction", null: false
    t.datetime "event_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_nostr_event_logs_on_channel_id"
    t.index ["event_id"], name: "index_nostr_event_logs_on_event_id", unique: true
    t.index ["message_id"], name: "index_nostr_event_logs_on_message_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "server_id", null: false
    t.bigint "channel_id", null: false
    t.bigint "message_id", null: false
    t.integer "notification_type", default: 0, null: false
    t.boolean "read", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["channel_id"], name: "index_notifications_on_channel_id"
    t.index ["message_id"], name: "index_notifications_on_message_id"
    t.index ["server_id"], name: "index_notifications_on_server_id"
    t.index ["user_id", "channel_id", "read"], name: "index_notifications_on_user_id_and_channel_id_and_read"
    t.index ["user_id", "read"], name: "index_notifications_on_user_id_and_read"
    t.index ["user_id", "server_id", "read"], name: "index_notifications_on_user_id_and_server_id_and_read"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "reactions", force: :cascade do |t|
    t.string "emoji"
    t.bigint "user_id", null: false
    t.bigint "message_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_reactions_on_message_id"
    t.index ["user_id", "message_id", "emoji"], name: "index_reactions_on_user_id_and_message_id_and_emoji", unique: true
    t.index ["user_id"], name: "index_reactions_on_user_id"
  end

  create_table "relay_connections", force: :cascade do |t|
    t.string "url", null: false
    t.string "status", default: "active"
    t.datetime "last_connected_at"
    t.datetime "last_error_at"
    t.text "last_error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["url"], name: "index_relay_connections_on_url", unique: true
  end

  create_table "remote_users", force: :cascade do |t|
    t.string "nostr_public_key", null: false
    t.string "home_instance", null: false
    t.string "display_name"
    t.string "avatar_url"
    t.text "bio"
    t.string "username"
    t.datetime "last_verified_at"
    t.string "public_id", limit: 12
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["home_instance"], name: "index_remote_users_on_home_instance"
    t.index ["nostr_public_key"], name: "index_remote_users_on_nostr_public_key", unique: true
    t.index ["public_id"], name: "index_remote_users_on_public_id", unique: true
  end

  create_table "roles", force: :cascade do |t|
    t.string "name"
    t.string "color"
    t.integer "position"
    t.boolean "mentionable"
    t.jsonb "permissions"
    t.bigint "server_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "public_id", limit: 12, null: false
    t.boolean "hoist", default: false, null: false
    t.index ["public_id"], name: "index_roles_on_public_id", unique: true
    t.index ["server_id"], name: "index_roles_on_server_id"
  end

  create_table "server_emojis", force: :cascade do |t|
    t.bigint "server_id", null: false
    t.bigint "creator_id", null: false
    t.string "name", limit: 32, null: false
    t.string "public_id", limit: 12, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_server_emojis_on_creator_id"
    t.index ["public_id"], name: "index_server_emojis_on_public_id", unique: true
    t.index ["server_id", "name"], name: "index_server_emojis_on_server_id_and_name", unique: true
    t.index ["server_id"], name: "index_server_emojis_on_server_id"
  end

  create_table "server_folders", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", limit: 50, default: "Folder", null: false
    t.integer "position", default: 0, null: false
    t.string "public_id", limit: 12, null: false
    t.boolean "collapsed", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "color", limit: 7, default: "#4f545c"
    t.index ["public_id"], name: "index_server_folders_on_public_id", unique: true
    t.index ["user_id", "position"], name: "index_server_folders_on_user_id_and_position"
    t.index ["user_id"], name: "index_server_folders_on_user_id"
  end

  create_table "server_memberships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "server_id", null: false
    t.string "nickname"
    t.datetime "joined_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "public_id", limit: 12, null: false
    t.integer "position", default: 0, null: false
    t.bigint "server_folder_id"
    t.index ["public_id"], name: "index_server_memberships_on_public_id", unique: true
    t.index ["server_folder_id"], name: "index_server_memberships_on_server_folder_id"
    t.index ["server_id"], name: "index_server_memberships_on_server_id"
    t.index ["user_id", "server_id"], name: "index_server_memberships_on_user_id_and_server_id", unique: true
    t.index ["user_id"], name: "index_server_memberships_on_user_id"
  end

  create_table "server_stickers", force: :cascade do |t|
    t.bigint "server_id", null: false
    t.bigint "creator_id", null: false
    t.string "name", limit: 50, null: false
    t.string "description", limit: 100
    t.string "public_id", limit: 12, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_server_stickers_on_creator_id"
    t.index ["public_id"], name: "index_server_stickers_on_public_id", unique: true
    t.index ["server_id", "name"], name: "index_server_stickers_on_server_id_and_name", unique: true
    t.index ["server_id"], name: "index_server_stickers_on_server_id"
  end

  create_table "servers", force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.string "invite_code"
    t.bigint "owner_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "welcome_channel_id"
    t.boolean "welcome_message_enabled", default: true
    t.text "welcome_message_template", default: "Welcome to the server, {user}! 🎉"
    t.string "public_id", limit: 12, null: false
    t.index ["invite_code"], name: "index_servers_on_invite_code", unique: true
    t.index ["owner_id"], name: "index_servers_on_owner_id"
    t.index ["public_id"], name: "index_servers_on_public_id", unique: true
    t.index ["welcome_channel_id"], name: "index_servers_on_welcome_channel_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.string "username", null: false
    t.string "display_name"
    t.text "bio"
    t.string "status"
    t.string "status_emoji"
    t.datetime "custom_status_expires_at"
    t.integer "online_state", default: 0, null: false
    t.datetime "online_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "discriminator", limit: 4, default: "0000", null: false
    t.string "profile_color"
    t.integer "banner_offset_y"
    t.string "profile_color_2"
    t.string "public_id", limit: 12, null: false
    t.string "nostr_public_key"
    t.text "nostr_encrypted_private_key"
    t.boolean "instance_admin", default: false, null: false
    t.boolean "remote", default: false, null: false
    t.bigint "remote_user_detail_id"
    t.datetime "nostr_profile_published_at"
    t.datetime "nostr_contacts_published_at"
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["nostr_public_key"], name: "index_users_on_nostr_public_key", unique: true
    t.index ["public_id"], name: "index_users_on_public_id", unique: true
    t.index ["remote_user_detail_id"], name: "index_users_on_remote_user_detail_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["username", "discriminator"], name: "index_users_on_username_and_discriminator", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.string "whodunnit"
    t.datetime "created_at"
    t.bigint "item_id", null: false
    t.string "item_type", null: false
    t.string "event", null: false
    t.text "object"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "bans", "servers"
  add_foreign_key "bans", "users"
  add_foreign_key "bans", "users", column: "banned_by_id"
  add_foreign_key "blocks", "users", column: "blocked_id"
  add_foreign_key "blocks", "users", column: "blocker_id"
  add_foreign_key "categories", "servers"
  add_foreign_key "channel_reads", "channels"
  add_foreign_key "channel_reads", "users"
  add_foreign_key "channels", "categories"
  add_foreign_key "channels", "servers"
  add_foreign_key "conversation_participants", "conversations"
  add_foreign_key "conversation_participants", "users"
  add_foreign_key "friendships", "users"
  add_foreign_key "friendships", "users", column: "friend_id"
  add_foreign_key "gif_collections", "users"
  add_foreign_key "gif_favorites", "gif_collections"
  add_foreign_key "gif_favorites", "users"
  add_foreign_key "instance_blocklists", "users", column: "blocked_by_id"
  add_foreign_key "invites", "servers"
  add_foreign_key "invites", "users", column: "creator_id"
  add_foreign_key "membership_roles", "roles"
  add_foreign_key "membership_roles", "server_memberships"
  add_foreign_key "messages", "channels"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "messages", column: "parent_id"
  add_foreign_key "messages", "users"
  add_foreign_key "moderation_reports", "users", column: "reporter_id"
  add_foreign_key "moderation_reports", "users", column: "reviewed_by_id"
  add_foreign_key "nostr_event_logs", "channels"
  add_foreign_key "nostr_event_logs", "messages"
  add_foreign_key "notifications", "channels"
  add_foreign_key "notifications", "messages"
  add_foreign_key "notifications", "servers"
  add_foreign_key "notifications", "users"
  add_foreign_key "reactions", "messages"
  add_foreign_key "reactions", "users"
  add_foreign_key "roles", "servers"
  add_foreign_key "server_emojis", "servers"
  add_foreign_key "server_emojis", "users", column: "creator_id"
  add_foreign_key "server_folders", "users"
  add_foreign_key "server_memberships", "server_folders"
  add_foreign_key "server_memberships", "servers"
  add_foreign_key "server_memberships", "users"
  add_foreign_key "server_stickers", "servers"
  add_foreign_key "server_stickers", "users", column: "creator_id"
  add_foreign_key "servers", "channels", column: "welcome_channel_id", on_delete: :nullify
  add_foreign_key "servers", "users", column: "owner_id"
  add_foreign_key "users", "remote_users", column: "remote_user_detail_id"
end
