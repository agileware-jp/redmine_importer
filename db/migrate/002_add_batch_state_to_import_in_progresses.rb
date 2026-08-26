# frozen_string_literal: true

class AddBatchStateToImportInProgresses < ActiveRecord::Migration[6.1]
  def change
    add_column :import_in_progresses, :settings, :text
    add_column :import_in_progresses, :total_items, :integer
    add_column :import_in_progresses, :position, :integer, default: 0, null: false
    add_column :import_in_progresses, :finished, :boolean, default: false, null: false
  end
end
