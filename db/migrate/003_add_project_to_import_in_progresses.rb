# frozen_string_literal: true

class AddProjectToImportInProgresses < ActiveRecord::Migration[6.1]
  def change
    # The project the import was started on. run/result requests whose URL
    # points at a different project are rejected, so a stale tab cannot
    # import the remaining rows into an unrelated project (#117121).
    add_column :import_in_progresses, :project_id, :integer
  end
end
