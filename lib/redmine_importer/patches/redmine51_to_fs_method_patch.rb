# frozen_string_literal: true

module RedmineImporter
  module Patches
    module Redmine51ToFsMethodPatch
      # redmine-5.1以前でもredmine-6.0.0以降と同様に呼べるto_fsメソッドを追加する
      to_fs_method_defined_modules_or_classes = [
        ActiveSupport::NumericWithFormat,
        ActiveSupport::RangeWithFormat,
        ActiveSupport::TimeWithZone,
        Array,
        Date,
        DateTime,
        Time,
      ]
      to_fs_method_defined_modules_or_classes.each do |c|
        next if c.method_defined?(:to_fs)

        refine(c) do
          alias_method(:to_fs, :to_s)
        end
      end
    end
  end
end
