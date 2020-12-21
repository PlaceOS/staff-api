class ICalMetadataMigration
  include Clear::Migration

  def change(direction)
    direction.up do
      execute("ALTER TABLE event_metadatas ADD COLUMN ical_uid TEXT")
    end

    direction.down do
      execute("ALTER TABLE event_metadatas DROP COLUMN ical_uid")
    end
  end
end
