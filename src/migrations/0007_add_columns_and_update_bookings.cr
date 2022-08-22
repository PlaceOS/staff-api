class AddColumnsAndUpdateBookingsToEventMetadatas
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE bookings ADD COLUMN booked_by_id TEXT")
      execute("ALTER TABLE bookings ADD COLUMN booked_by_email TEXT")
      execute("ALTER TABLE bookings ADD COLUMN booked_by_name TEXT")
      execute("ALTER TABLE bookings ADD COLUMN process_state TEXT")

      execute("CREATE INDEX bookings_process_state_idx ON bookings (process_state)")

      # migrate the data
      execute("UPDATE bookings SET booked_by_id = user_id WHERE booked_by_id IS NULL")
      execute("UPDATE bookings SET booked_by_email = user_email WHERE booked_by_email IS NULL")
      execute("UPDATE bookings SET booked_by_name = user_name WHERE booked_by_name IS NULL")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE bookings DROP COLUMN booked_by_id")
      execute("ALTER TABLE bookings DROP COLUMN booked_by_email")
      execute("ALTER TABLE bookings DROP COLUMN booked_by_name")

      execute("DROP INDEX IF EXISTS bookings_process_state_idx")
      execute("ALTER TABLE bookings DROP COLUMN process_state")
    end
  end
end
