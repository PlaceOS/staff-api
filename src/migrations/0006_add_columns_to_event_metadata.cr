# Metadata ICAL_UID
class AddColumnsToEventMetadatas
  include Clear::Migration

  def change(dir)
    dir.up do
      # Remove the unique constraint on the event_id index
      execute("DROP INDEX IF EXISTS event_metadatas_event_id_idx")
      execute("CREATE INDEX event_metadatas_event_id_idx ON event_metadatas (event_id)")

      # Add the new columns
      execute("ALTER TABLE event_metadatas ADD COLUMN ical_uid TEXT")
      execute("ALTER TABLE event_metadatas ADD COLUMN recurring_master_id TEXT")

      # Create an index on ical_uid
      execute("CREATE INDEX event_metadatas_ical_uid_idx ON event_metadatas (ical_uid)")
    end

    dir.down do
      # remove index on ical_uid
      execute("DROP INDEX IF EXISTS event_metadatas_ical_uid_idx")

      # remove the new columns
      execute("ALTER TABLE event_metadatas DROP COLUMN ical_uid")
      execute("ALTER TABLE event_metadatas DROP COLUMN recurring_master_id")

      # Restore the unique constraint
      execute("DROP INDEX IF EXISTS event_metadatas_event_id_idx")
      execute("CREATE UNIQUE INDEX event_metadatas_event_id_idx ON event_metadatas (event_id)")
    end
  end
end
