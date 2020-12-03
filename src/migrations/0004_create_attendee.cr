class CreateAttendeeMigration
  include Clear::Migration

  def change(direction)
    direction.up do
      create_table(:attendees) do |t|
        t.references to: "event_metadatas", name: "event_id", on_delete: "cascade", null: false
        t.references to: "guests", name: "guest_id", on_delete: "cascade", null: false
        t.references to: "tenants", name: "tenant_id", on_delete: "cascade", null: false

        t.column :checked_in, :boolean, default: false
        t.column :visit_expected, :boolean, default: true

        t.timestamps
      end
    end

    direction.down do
      execute("DROP TABLE attendees")
    end
  end
end
