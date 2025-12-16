# frozen_string_literal: true

module RedmineImporter
  # Manages deferred callbacks for resolving references to issues
  # that haven't been imported yet (e.g., parent issues or relations
  # defined later in the CSV file).
  class DeferredCallbacks
    def initialize(issue_cache:, messages:)
      @pending = {}
      @issue_cache = issue_cache
      @messages = messages
    end

    # Registers a callback to be executed when an issue with the given
    # unique_value is imported.
    def register(unique_value, callback_name, *args)
      @pending[unique_value] ||= []
      @pending[unique_value] << [callback_name, args]
    end

    # Executes pending callbacks for the given unique_value.
    def execute(unique_value, object)
      return unless (callbacks = @pending.delete(unique_value))

      callbacks.each do |name, args|
        send(:"#{name}_callback", object, *args)
      end
    end

    # Returns hash of unresolved callbacks.
    def unresolved
      @pending
    end

    # Adds warning messages for any callbacks that were never resolved.
    def warn_unresolved
      @pending.each do |unique_value, callbacks|
        callbacks.each do |name, _args|
          @messages << "Warning: Deferred #{name} for '#{unique_value}' " \
                       'was never resolved (target issue not found in CSV)'
        end
      end
    end

    private

    # Callback: Sets parent for a previously imported issue.
    def set_parent_callback(parent_issue, child_unique_value)
      child_issue = @issue_cache[child_unique_value]
      return unless child_issue

      # Reload to get latest version and avoid StaleObjectError
      child_issue.reload
      child_issue.parent_issue_id = parent_issue.id
      unless child_issue.save
        @messages << "Warning: Failed to set parent for issue '#{child_unique_value}': " \
                     "#{child_issue.errors.full_messages.join(', ')}"
      end
    end

    # Callback: Creates a relation between two previously imported issues.
    def add_relation_callback(to_issue, from_unique_value, relation_type)
      from_issue = @issue_cache[from_unique_value]
      return unless from_issue

      relation = IssueRelation.new(
        issue_from: from_issue,
        issue_to: to_issue,
        relation_type: relation_type
      )
      unless relation.save
        @messages << "Warning: Failed to create relation: #{relation.errors.full_messages.join(', ')}"
      end
    end
  end
end
