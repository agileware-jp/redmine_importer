# frozen_string_literal: true

module RedmineImporter
  module Concerns
    module ValidateStatus
      extend ActiveSupport::Concern

      included do
        validate do
          if status.is_closed? && descendants.open.exists?
            # NOTE: prefer an appropriate error
            errors.add(:status_id, :inclusion)
          end

          if !status.is_closed? && ancestors.joins(:status).merge(IssueStatus.where(is_closed: true)).exists?
            # NOTE: prefer an appropriate error
            errors.add(:status_id, :inclusion)
          end
        end
      end
    end
  end
end
