class AssociateAttendeeWithBooking
  include Clear::Migration

  def change(direction)
    direction.up do
      execute("ALTER TABLE bookings ADD COLUMN email_digest TEXT")
      execute("ALTER TABLE bookings ADD COLUMN booked_by_email_digest TEXT")

      execute("ALTER TABLE bookings ADD COLUMN deleted_at BIGINT")
      execute("ALTER TABLE bookings ADD COLUMN deleted BOOLEAN DEFAULT FALSE")
    end

    direction.down do
      execute("ALTER TABLE bookings DROP COLUMN deleted")
      execute("ALTER TABLE bookings DROP COLUMN deleted_at")

      execute("ALTER TABLE bookings DROP COLUMN booked_by_email_digest")
      execute("ALTER TABLE bookings DROP COLUMN email_digest")
    end
  end
end
