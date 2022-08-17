class CreateBookingsMigration
  include Clear::Migration

  def change(dir)
    dir.up do
      create_table(:bookings) do |t|
        t.references to: "tenants", name: "tenant_id", on_delete: "cascade", null: false

        t.column :user_id, :string
        t.column :user_email, :string
        t.column :user_name, :string
        t.column :asset_id, :string
        t.column :zones, "text[]"

        t.column :booking_type, :string
        t.column :booking_start, :bigint
        t.column :booking_end, :bigint
        t.column :timezone, :string

        t.column :title, :string
        t.column :description, :string
        t.column :checked_in, :boolean, default: "false"

        t.column :rejected, :boolean, default: "false"
        t.column :approved, :boolean, default: "false"
        t.column :approver_id, :string
        t.column :approver_email, :string
        t.column :approver_name, :string

        t.column :ext_data, :jsonb, default: "'{}'"
        t.timestamps
      end
    end

    dir.down do
      execute("DROP TABLE bookings")
    end
  end
end
