# ALTER TABLE attendees ALTER COLUMN booking_id TYPE bigint
class AlterAttendeesBookingID
  include Clear::Migration

  def change(dir)
    dir.up do
      execute("ALTER TABLE attendees ALTER COLUMN booking_id TYPE bigint")
    end
  end
end
