class CreateSurveyMigration
  include Clear::Migration

  def change(dir)
    dir.up do
      create_table(:surveys) do |t|
        t.column :title, :text
        t.column :description, :text
        t.column :question_order, :bigint[]
        t.timestamps
      end

      create_table(:questions) do |t|
        t.column :title, :text
        t.column :description, :text
        t.column :type, :text
        t.column :question_options, :jsonb, default: "'{}'"
        t.timestamps
      end

      create_table(:answers) do |t|
        t.references to: "questions", name: "question_id", on_delete: "cascade", null: false
        t.references to: "surveys", name: "survey_id", on_delete: "cascade", null: false

        t.column :answer, :text
        t.timestamps
      end
    end

    dir.down do
      execute("DROP TABLE surveys")
      execute("DROP TABLE questions")
      execute("DROP TABLE answers")
    end
  end
end
