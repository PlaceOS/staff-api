class RenameExtColumn
  include Clear::Migration

  def change(direction)
    direction.up do
      # rename the ext_data columns
      execute("ALTER TABLE bookings RENAME COLUMN ext_data TO extension_data")
      execute("ALTER TABLE guests RENAME COLUMN ext_data TO extension_data")
    end

    direction.down do
      # revert column names
      execute("ALTER TABLE bookings RENAME COLUMN extension_data TO ext_data")
      execute("ALTER TABLE guests RENAME COLUMN extension_data TO ext_data")
    end
  end
end
