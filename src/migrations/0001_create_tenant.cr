class CreateTenantMigration
  include Clear::Migration

  def change(dir)
    dir.up do
      create_table(:tenants) do |t|
        t.column :name, :text
        t.column :domain, :text, unique: true, index: true
        t.column :platform, :text
        t.column :credentials, :text
        t.timestamps
      end
    end

    dir.down do
      execute("DROP TABLE tenants")
    end
  end
end
