class AddOutlookConfigToTenants
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE tenants ADD COLUMN outlook_config JSONB DEFAULT '{}'::jsonb")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE tenants DROP COLUMN outlook_config")
    end
  end
end
