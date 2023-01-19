class ChangeSurveyTables
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE questions ADD COLUMN required boolean DEFAULT 'false'")
      execute("ALTER TABLE questions ADD COLUMN choices JSONB DEFAULT '{}'::jsonb")
      execute("ALTER TABLE questions ADD COLUMN max_rating integer")
      execute("ALTER TABLE questions ADD COLUMN tags text[] DEFAULT '{}'")

      # create_enum(:survey_trigger_type, TriggerType)
      # changed to explicitly define enum values to avoid future issues
      # that may arise from changing the TriggerType enum but not the database,
      # if using the TriggerType enum directly then those issues would not be caught in dev/test
      create_enum(:survey_trigger_type, %w(NONE RESERVED CHECKEDIN CHECKEDOUT NOSHOW REJECTED CANCELLED ENDED))
      execute("ALTER TABLE surveys ADD COLUMN trigger survey_trigger_type DEFAULT 'NONE'")

      execute("ALTER TABLE surveys ADD COLUMN zone_id text")
      execute("ALTER TABLE surveys DROP COLUMN question_order")
      execute("ALTER TABLE surveys ADD COLUMN pages JSONB DEFAULT '[]'::jsonb")

      execute("ALTER TABLE answers ADD COLUMN type text")
      execute("ALTER TABLE answers DROP COLUMN answer_text")
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

      execute("ALTER TABLE answers DROP COLUMN type")
      execute("ALTER TABLE answers ADD COLUMN answer_text text")
    end
  end
end
