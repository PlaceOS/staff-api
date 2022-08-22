class CreateEventMetadataMigration
  include Clear::Migration

  def change(dir)
    dir.up do
      create_table(:event_metadatas) do |t|
        t.references to: "tenants", name: "tenant_id", on_delete: "cascade", null: false

        t.column :system_id, :text, index: true
        t.column :event_id, :text, unique: true, index: true

        t.column :host_email, :text
        t.column :resource_calendar, :text
        t.column :event_start, :bigint
        t.column :event_end, :bigint
        t.column :ext_data, :jsonb

        t.timestamps
      end
    end

    dir.down do
      execute("DROP TABLE event_metadatas")
    end
  end
end
