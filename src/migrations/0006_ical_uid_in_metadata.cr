class ICalMetadataMigration
  include Clear::Migration

  def change(direction)
    direction.up do
      execute("ALTER TABLE event_metadatas ADD COLUMN ical_uid TEXT")
      execute("CREATE INDEX ical_uid_index ON event_metadatas (ical_uid)")

      execute("ALTER TABLE event_metadatas ADD COLUMN recurring_master_id TEXT")
    end

    direction.down do
      execute("DROP INDEX IF EXISTS ical_uid_index")
      execute("ALTER TABLE event_metadatas DROP COLUMN ical_uid")

      execute("ALTER TABLE event_metadatas DROP COLUMN recurring_master_id")
    end
  end
end
