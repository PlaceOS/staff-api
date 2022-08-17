class AssociateAttendeeWithBooking
  include Clear::Migration

  def change(dir)
    dir.up do
      # add new column to attendees and allow event_id to be NULL
      execute("ALTER TABLE attendees ADD COLUMN booking_id integer, ADD FOREIGN KEY (booking_id) REFERENCES bookings(id)")
      execute("ALTER TABLE attendees ALTER COLUMN event_id DROP NOT NULL")
    end

    dir.down do
      # revert new column and add back the NO NULL requirement
      execute("ALTER TABLE attendees DROP COLUMN booking_id")
      execute("ALTER TABLE attendees ALTER COLUMN event_id SET NOT NULL")
    end
  end
end
