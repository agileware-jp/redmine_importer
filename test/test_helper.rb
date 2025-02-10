# frozen_string_literal: true

require 'test_helper'

module RedmineImporter
  module TestHelper
    def self.included(base)
      base.fixtures :all if Redmine::VERSION.to_s >= '5.1.6'
    end
  end
end

ActiveSupport::TestCase.include RedmineImporter::TestHelper
