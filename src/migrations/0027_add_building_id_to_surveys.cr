class AddBuildingIdToSurveys
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE surveys ADD COLUMN building_id text")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE surveys DROP COLUMN building_id")
    end
  end
end
