class AddTimestampsToBookings
  include Clear::Migration

  def change(direction)
    direction.up do
      # Add the new columns
      execute("ALTER TABLE bookings ADD COLUMN checked_in_at BIGINT")
      execute("ALTER TABLE bookings ADD COLUMN checked_out_at BIGINT")
      execute("ALTER TABLE bookings ADD COLUMN rejected_at BIGINT")
      execute("ALTER TABLE bookings ADD COLUMN approved_at BIGINT")
      execute("ALTER TABLE bookings ADD COLUMN booked_from TEXT")
    end

    direction.down do
      # remove the new columns
      execute("ALTER TABLE bookings DROP COLUMN booked_from")
      execute("ALTER TABLE bookings DROP COLUMN approved_at")
      execute("ALTER TABLE bookings DROP COLUMN rejected_at")
      execute("ALTER TABLE bookings DROP COLUMN checked_out_at")
      execute("ALTER TABLE bookings DROP COLUMN checked_in_at")
    end
  end
end
