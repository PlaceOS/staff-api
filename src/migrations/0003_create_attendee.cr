class CreateAttendeeMigration
  include Clear::Migration

  def change(direction)
    direction.up do
      create_table(:attendees) do |t|
        t.references to: "event_metadatas", name: "event_id", on_delete: "cascade", null: false

        t.column :checked_in, :boolean, default: false
        t.column :visit_expected, :boolean, default: true
        t.column :guest_id, :string, index: true

        t.timestamps
      end

      direction.down do
        execute("DROP TABLE attendees")
      end
    end
  end
end
