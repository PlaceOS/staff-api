class AddColumnsAndUpdateBookingsToEventMetadatas
  include Clear::Migration

  def change(direction)
    direction.up do
      # Add the new columns
      add_column "bookings", "booked_by_id", "text"
      add_column "bookings", "booked_by_email", "text"
      add_column "bookings", "booked_by_name", "text"
      add_column "bookings", "process_state", "text"

      execute("CREATE INDEX bookings_process_state_idx ON bookings (process_state)")

      # migrate the data
      execute "UPDATE bookings SET booked_by_id = user_id WHERE booked_by_id IS NULL"
      execute "UPDATE bookings SET booked_by_email = user_email WHERE booked_by_email IS NULL"
      execute "UPDATE bookings SET booked_by_name = user_name WHERE booked_by_name IS NULL"
    end

    direction.down do
      # remove the new columns
      execute("ALTER TABLE bookings DROP COLUMN booked_by_id")
      execute("ALTER TABLE bookings DROP COLUMN booked_by_email")
      execute("ALTER TABLE bookings DROP COLUMN booked_by_name")

      execute("DROP INDEX IF EXISTS bookings_process_state_idx")
      execute("ALTER TABLE bookings DROP COLUMN process_state")
    end
  end
end
