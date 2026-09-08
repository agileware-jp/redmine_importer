# frozen_string_literal: true

module RedmineImporter
  # Cache of imported issues indexed by the value of the user-selected unique
  # column. Only the issue ids are persisted between batch requests
  # (via ImportInProgress#import_settings); Issue records are loaded lazily
  # and memoized within a request.
  class IssueUniqueCache
    def initialize(ids = {})
      @ids = ids || {}
      @issues = {}
    end

    # Ids by unique value, as persisted between requests.
    attr_reader :ids

    def key?(value)
      @ids.key?(value)
    end

    def [](value)
      return nil unless (id = @ids[value])

      @issues[value] ||= Issue.find_by_id(id)
    end

    def []=(value, issue)
      @ids[value] = issue.id
      @issues[value] = issue
    end
  end
end
