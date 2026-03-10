class AddProgressToImportInProgresses < ActiveRecord::Migration[5.2]
  def change
    add_column :import_in_progresses, :total_rows, :integer, default: 0
    add_column :import_in_progresses, :processed_rows, :integer, default: 0
    add_column :import_in_progresses, :status, :string, default: 'pending', limit: 20
  end
end
