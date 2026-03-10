class AddProjectIdToImportInProgresses < ActiveRecord::Migration[5.2]
  def change
    add_column :import_in_progresses, :project_id, :integer
    add_index :import_in_progresses, [:user_id, :project_id]
  end
end
