class AddPublicIdToModels < ActiveRecord::Migration[8.0]
  def up
    tables = %i[servers channels users messages conversations categories roles server_memberships]

    tables.each do |table|
      add_column table, :public_id, :string, limit: 12
    end

    # Backfill existing records
    tables.each do |table|
      execute <<-SQL
        UPDATE #{table} SET public_id = substr(md5(random()::text || clock_timestamp()::text), 1, 12) WHERE public_id IS NULL
      SQL
    end

    # Add NOT NULL constraint and unique index
    tables.each do |table|
      change_column_null table, :public_id, false
      add_index table, :public_id, unique: true
    end

    # Clear cached rendered_content that has baked-in numeric data-user-id attributes
    execute <<-SQL
      UPDATE messages SET rendered_content_cached = NULL WHERE rendered_content_cached LIKE '%data-user-id%'
    SQL
  end

  def down
    %i[servers channels users messages conversations categories roles server_memberships].each do |table|
      remove_column table, :public_id
    end
  end
end
