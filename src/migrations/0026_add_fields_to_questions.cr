class AddFieldsToQuestions
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE questions ADD COLUMN required boolean DEFAULT 'false'")
      execute("ALTER TABLE questions ADD COLUMN choices JSONB DEFAULT '{}'::jsonb")
      execute("ALTER TABLE questions ADD COLUMN max_rating integer DEFAULT 0")
      execute("ALTER TABLE questions ADD COLUMN tags text[] DEFAULT '{}'")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE questions DROP COLUMN required")
      execute("ALTER TABLE questions DROP COLUMN choices")
      execute("ALTER TABLE questions DROP COLUMN max_rating")
      execute("ALTER TABLE questions DROP COLUMN tags")
    end
  end
end
