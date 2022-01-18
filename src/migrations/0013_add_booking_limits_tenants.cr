class AddBookingLimitsToTenants
  include Clear::Migration

  def change(direction)
    direction.up do
      # Add the new columns
      execute("ALTER TABLE tenants ADD COLUMN booking_limits JSONB DEFAULT '{}'::jsonb")
    end

    direction.down do
      # remove the new columns
      execute("ALTER TABLE tenants DROP COLUMN booking_limits")
    end
  end
end
