class AddHistoryToBookings
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE bookings ADD COLUMN history JSONB DEFAULT '[]'::jsonb")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE bookings DROP COLUMN history")
    end
  end
end
