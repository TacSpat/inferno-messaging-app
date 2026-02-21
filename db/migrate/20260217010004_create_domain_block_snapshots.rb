class CreateDomainBlockSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :domain_block_snapshots do |t|
      t.references :instance_blocklist, null: false, foreign_key: true, index: { unique: true }
      t.json :snapshot_data, null: false, default: {}
      t.timestamps
    end
  end
end
