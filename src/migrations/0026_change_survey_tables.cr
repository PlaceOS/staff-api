class ChangeSurveyTables
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE questions ADD COLUMN required boolean DEFAULT 'false'")
      execute("ALTER TABLE questions ADD COLUMN choices JSONB DEFAULT '{}'::jsonb")
      execute("ALTER TABLE questions ADD COLUMN max_rating integer")
      execute("ALTER TABLE questions ADD COLUMN tags text[] DEFAULT '{}'")

      create_enum(:survey_trigger_type, TriggerType)
      execute("ALTER TABLE surveys ADD COLUMN trigger survey_trigger_type DEFAULT 'NONE'")

      execute("ALTER TABLE surveys ADD COLUMN zone_id text")
      execute("ALTER TABLE surveys DROP COLUMN question_order")
      execute("ALTER TABLE surveys ADD COLUMN pages JSONB DEFAULT '[]'::jsonb")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE questions DROP COLUMN required")
      execute("ALTER TABLE questions DROP COLUMN choices")
      execute("ALTER TABLE questions DROP COLUMN max_rating")
      execute("ALTER TABLE questions DROP COLUMN tags")

      execute("ALTER TABLE surveys DROP COLUMN trigger")
      execute("DROP TYPE IF EXISTS survey_trigger_type")

      execute("ALTER TABLE surveys DROP COLUMN zone_id")
      execute("ALTER TABLE surveys ADD COLUMN question_order bigint[] DEFAULT '{}'")
      execute("ALTER TABLE surveys DROP COLUMN pages")
    end
  end
end
