class AddDeletedAtToQuestions
  include Clear::Migration

  def change(dir)
    dir.up do
      # Add the new columns
      execute("ALTER TABLE questions ADD COLUMN deleted_at BIGINT")
    end

    dir.down do
      # remove the new columns
      execute("ALTER TABLE questions DROP COLUMN deleted_at")
    end
  end
end
