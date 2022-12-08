class CreateSurveyinvitation
  include Clear::Migration

  def change(dir)
    dir.up do
      create_table(:survey_invitations) do |t|
        t.references to: "surveys", name: "survey_id", on_delete: "cascade", null: false

        t.column :token, :text, unique: true, index: true
        t.column :email, :text
        t.column :sent, :boolean, default: "false"
        t.timestamps
      end
    end

    dir.down do
      execute("DROP TABLE survey_invitations")
    end
  end
end
