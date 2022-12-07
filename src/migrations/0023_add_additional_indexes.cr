class AddAdditionalIndexes
  include Clear::Migration

  def change(dir)
    dir.up do
      execute("CREATE INDEX IF NOT EXISTS bookings_booking_start_end_idx ON bookings (booking_start, booking_end)")
      execute("CREATE INDEX IF NOT EXISTS bookings_booking_user_id_idx ON bookings (user_id)")
      execute("CREATE INDEX IF NOT EXISTS bookings_booking_email_digest_idx ON bookings (email_digest)")
    end

    dir.down do
      execute("DROP INDEX IF EXISTS bookings_booking_start_end_idx")
      execute("DROP INDEX IF EXISTS bookings_booking_user_id_idx")
      execute("DROP INDEX IF EXISTS bookings_booking_email_digest_idx")
    end
  end
end
