class AddTimestampsToBookings
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE bookings ADD COLUMN last_changed BIGINT")
      execute("ALTER TABLE bookings ADD COLUMN created BIGINT")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE bookings DROP COLUMN created")
      execute("ALTER TABLE bookings DROP COLUMN last_changed")
    end
  end
end
