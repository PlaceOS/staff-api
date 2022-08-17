class AddEventIdToBookings
  include Clear::Migration

  def change(dir)
    dir.up do
      execute("ALTER TABLE bookings ADD COLUMN event_id TEXT")
    end

    dir.down do
      execute("ALTER TABLE bookings DROP COLUMN event_id")
    end
  end
end
