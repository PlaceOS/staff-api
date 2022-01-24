class AddHistoryToBookings
  include Clear::Migration

  def change(direction)
    direction.up do
      # Add the new columns
      execute("ALTER TABLE bookings ADD COLUMN history JSONB DEFAULT '[]'::jsonb")
    end

    direction.down do
      # remove the new columns
      execute("ALTER TABLE bookings DROP COLUMN history")
    end
  end
end
