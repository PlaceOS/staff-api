class CreateEventMetadataMigration
  include Clear::Migration

  def change(direction)
    direction.up do
      create_table(:event_metadatas) do |t|
        t.column :system_id, :text, index: true
        t.column :event_id, :text, unique: true, index: true

        t.column :host_email, :text
        t.column :resource_calendar, :text
        t.column :event_start, :bigint
        t.column :event_end, :bigint
        t.column :ext_data, :jsonb

        t.timestamps
      end

      direction.down do
        execute("DROP TABLE event_metadatas")
      end
    end
  end
end
