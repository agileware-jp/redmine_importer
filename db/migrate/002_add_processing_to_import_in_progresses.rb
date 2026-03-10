class AddProcessingToImportInProgresses < ActiveRecord::Migration[5.2]
  def change
    add_column :import_in_progresses, :processing, :boolean, default: false, null: false
  end
end
