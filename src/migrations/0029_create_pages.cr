class CreateSurveyMigration
  include Clear::Migration

  def change(dir)
    dir.up do
      create_table(:pages) do |t|
        t.column :title, :text
        t.column :description, :text
        t.column :question_order, "bigint[]"
        t.timestamps
      end

      execute("ALTER TABLE surveys ADD COLUMN page_order bigint[] DEFAULT '{}'")

      execute("ALTER TABLE surveys DROP COLUMN question_order")
    end

    dir.down do
      execute("DROP TABLE pages")
      execute("ALTER TABLE surveys DROP COLUMN page_order")
      execute("ALTER TABLE surveys ADD COLUMN question_order bigint[] DEFAULT '{}'")
    end
  end
end
