class CreateFederationAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :federation_audit_logs do |t|
      t.string :event_type, null: false
      t.string :actor_type
      t.bigint :actor_id
      t.string :target_type
      t.bigint :target_id
      t.string :remote_domain
      t.inet :ip_address
      t.jsonb :metadata, default: {}
      t.datetime :created_at, null: false
    end

    add_index :federation_audit_logs, [ :event_type, :created_at ]
    add_index :federation_audit_logs, [ :actor_type, :actor_id ]
    add_index :federation_audit_logs, [ :remote_domain, :created_at ]
    add_index :federation_audit_logs, [ :target_type, :target_id ]
  end
end
