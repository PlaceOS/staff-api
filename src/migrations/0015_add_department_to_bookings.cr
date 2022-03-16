class AddDepartmentToBookings
  include Clear::Migration

  def change(direction)
    direction.up do
      # Add the new columns
      execute("ALTER TABLE bookings ADD COLUMN department TEXT")
    end

    direction.down do
      # remove the new columns
      execute("ALTER TABLE bookings DROP COLUMN department")
    end
  end
end
