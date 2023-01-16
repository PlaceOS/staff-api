class AddFieldsToSurveys
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      create_enum(:survey_trigger_type, TriggerType)
      execute("ALTER TABLE surveys ADD COLUMN trigger survey_trigger_type DEFAULT 'NONE'")
      execute("ALTER TABLE surveys ADD COLUMN zone_id text")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE surveys DROP COLUMN trigger")
      execute("DROP TYPE IF EXISTS survey_trigger_type")
      execute("ALTER TABLE surveys DROP COLUMN zone_id")
    end
  end
end
