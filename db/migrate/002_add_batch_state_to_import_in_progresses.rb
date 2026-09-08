# frozen_string_literal: true

class AddBatchStateToImportInProgresses < ActiveRecord::Migration[6.1]
  def change
    # The per-row state stored in settings grows with the CSV size and
    # exceeds MySQL's 64 KB TEXT at roughly 4-5k rows. 1 GB - 1 is the
    # largest limit accepted by both adapters: MySQL maps any limit above
    # 16 MB to LONGTEXT, and PostgreSQL (where text is unbounded anyway)
    # raises on limits above 1 GB - 1.
    add_column :import_in_progresses, :settings, :text, limit: 1_073_741_823
    add_column :import_in_progresses, :total_items, :integer
    add_column :import_in_progresses, :position, :integer, default: 0, null: false
    add_column :import_in_progresses, :finished, :boolean, default: false, null: false
  end
end
