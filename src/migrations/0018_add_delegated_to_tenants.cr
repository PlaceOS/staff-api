class AddDelegatedToTenants
  include Clear::Migration

  def change(direction)
    direction.up do
      execute("ALTER TABLE tenants ADD COLUMN delegated BOOLEAN DEFAULT FALSE")
    end

    direction.down do
      execute("ALTER TABLE tenants DROP COLUMN delegated")
    end
  end
end
