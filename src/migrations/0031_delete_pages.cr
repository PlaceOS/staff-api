class CreateSurveyMigration
  include Clear::Migration

  def change(dir)
    dir.up do
      execute("DROP TABLE pages")
    end

    dir.down do
      create_table(:pages) do |t|
        t.column :title, :text
        t.column :description, :text
        t.column :question_order, "bigint[]"
        t.timestamps
      end
    end
  end
end
