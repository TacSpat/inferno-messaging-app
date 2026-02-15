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

ActiveRecord::Schema[8.0].define(version: 2026_02_14_220957) do
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
    t.index ["category_id"], name: "index_channels_on_category_id"
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
    t.index ["public_id"], name: "index_roles_on_public_id", unique: true
    t.index ["server_id"], name: "index_roles_on_server_id"
  end

  create_table "server_memberships", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "server_id", null: false
    t.bigint "role_id"
    t.string "nickname"
    t.datetime "joined_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "public_id", limit: 12, null: false
    t.index ["public_id"], name: "index_server_memberships_on_public_id", unique: true
    t.index ["role_id"], name: "index_server_memberships_on_role_id"
    t.index ["server_id"], name: "index_server_memberships_on_server_id"
    t.index ["user_id", "server_id"], name: "index_server_memberships_on_user_id_and_server_id", unique: true
    t.index ["user_id"], name: "index_server_memberships_on_user_id"
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
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["public_id"], name: "index_users_on_public_id", unique: true
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
  add_foreign_key "invites", "servers"
  add_foreign_key "invites", "users", column: "creator_id"
  add_foreign_key "messages", "channels"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "messages", column: "parent_id"
  add_foreign_key "messages", "users"
  add_foreign_key "notifications", "channels"
  add_foreign_key "notifications", "messages"
  add_foreign_key "notifications", "servers"
  add_foreign_key "notifications", "users"
  add_foreign_key "reactions", "messages"
  add_foreign_key "reactions", "users"
  add_foreign_key "roles", "servers"
  add_foreign_key "server_memberships", "roles"
  add_foreign_key "server_memberships", "servers"
  add_foreign_key "server_memberships", "users"
  add_foreign_key "servers", "channels", column: "welcome_channel_id", on_delete: :nullify
  add_foreign_key "servers", "users", column: "owner_id"
end
