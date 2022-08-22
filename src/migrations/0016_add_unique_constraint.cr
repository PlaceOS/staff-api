class AddUniqueConstraint
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the unique constraints
      execute("ALTER TABLE tenants ADD CONSTRAINT unique_domain UNIQUE(domain)")
      execute("ALTER TABLE guests ADD CONSTRAINT unique_email UNIQUE(email, tenant_id)")
    end

    dir.down do
      # remove the unique constraints
      execute("ALTER TABLE tenants DROP CONSTRAINT unique_domain UNIQUE(domain)")
      execute("ALTER TABLE guests DROP CONSTRAINT unique_email UNIQUE(email, tenant_id)")
    end
  end
end
