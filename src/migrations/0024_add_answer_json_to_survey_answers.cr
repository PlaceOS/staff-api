class AddAnswerJsonToSurveyAnswers
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE answers ADD COLUMN answer_json JSONB DEFAULT '{}'::jsonb")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE answers DROP COLUMN answer_json")
    end
  end
end
