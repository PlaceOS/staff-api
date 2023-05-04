class AlterEnumTriggerType
  include Clear::Migration

  def change(dir)
    dir.up do
      execute("ALTER TYPE survey_trigger_type ADD VALUE 'VISITOR_CHECKEDIN'")
      execute("ALTER TYPE survey_trigger_type ADD VALUE 'VISITOR_CHECKEDOUT'")
    end

    # No down migration, as enum does not support removal of values
  end
end
