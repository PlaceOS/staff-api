class AddDelegatedToTenants
  include Clear::Migration

  def change(dir)
    dir.up do
      execute("ALTER TABLE tenants ADD COLUMN delegated BOOLEAN DEFAULT FALSE")
    end

    dir.down do
      execute("ALTER TABLE tenants DROP COLUMN delegated")
    end
  end
end
