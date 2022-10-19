class AddServiceAccountToTenants
  include Clear::Migration

  def change(dir)
    dir.up do
      execute("ALTER TABLE tenants ADD COLUMN service_account TEXT")
    end

    dir.down do
      execute("ALTER TABLE tenants DROP COLUMN service_account")
    end
  end
end
