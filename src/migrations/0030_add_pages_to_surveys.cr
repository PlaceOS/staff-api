class AddPagesToSurveys
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE surveys ADD COLUMN pages JSONB DEFAULT '[]'::jsonb")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE surveys DROP COLUMN pages")
    end
  end
end
