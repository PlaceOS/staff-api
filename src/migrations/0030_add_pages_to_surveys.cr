class AddPagesToSurveys
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE surveys ADD COLUMN pages JSONB DEFAULT '[]'::jsonb")
      execute("ALTER TABLE surveys DROP COLUMN page_order")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE surveys DROP COLUMN pages")
      execute("ALTER TABLE surveys ADD COLUMN page_order bigint[] DEFAULT '{}'")
    end
  end
end
