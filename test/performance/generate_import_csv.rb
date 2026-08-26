# frozen_string_literal: true

# Generates large CSV files for benchmarking ImporterController#result.
#
# Usage (CLI):
#   ruby test/performance/generate_import_csv.rb ROWS [VARIANT] [OUTPUT]
#
#   ROWS    - number of data rows to generate
#   VARIANT - basic | custom_fields | parent | full (default: basic)
#   OUTPUT  - output file path (default: stdout)
#
# Usage (from tests):
#   require_relative 'generate_import_csv'
#   csv = ImportCsvGenerator.generate(rows: 5000, variant: :full)
#
# Variants (all include a sequential "#" column used as the unique field):
#   basic         - standard fields only (subject, description, priority,
#                   tracker, status). Exercises the per-row master-data
#                   lookups in the import loop.
#   custom_fields - basic + a multi-value list custom field column ("Tags").
#   parent        - basic + a "Parent" column. Within each group of
#                   GROUP_SIZE rows the parent row comes LAST, so the child
#                   rows are forward references that go through the deferred
#                   callback mechanism (matches Redmine's export order where
#                   newer issues appear first).
#   full          - all of the above.
require 'csv'

module ImportCsvGenerator
  GROUP_SIZE = 10

  DEFAULTS = {
    priority: 'Critical',
    tracker: 'Defect',
    status: 'New',
    tags: 'tag1,tag2'
  }.freeze

  module_function

  def generate(rows:, variant: :basic, **overrides)
    variant = variant.to_sym
    values = DEFAULTS.merge(overrides)
    with_tags = %i[custom_fields full].include?(variant)
    with_parent = %i[parent full].include?(variant)

    CSV.generate(force_quotes: true) do |csv|
      csv << headers(with_tags: with_tags, with_parent: with_parent)
      1.upto(rows) do |n|
        row = []
        row << n.to_s
        row << "Benchmark issue #{n}"
        row << "Generated row #{n} for import benchmark."
        row << values[:priority]
        row << values[:tracker]
        row << values[:status]
        row << values[:tags] if with_tags
        row << parent_ref(n, rows) if with_parent
        csv << row
      end
    end
  end

  def headers(with_tags:, with_parent:)
    headers = ['#']
    headers += %w[Subject Description Priority Tracker Status]
    headers << 'Tags' if with_tags
    headers << 'Parent' if with_parent
    headers
  end

  # The last row of each group is the parent; earlier rows in the group
  # reference it before it exists (forward reference).
  def parent_ref(n, rows)
    group_last = [((n - 1) / GROUP_SIZE + 1) * GROUP_SIZE, rows].min
    n == group_last ? '' : group_last.to_s
  end
end

if __FILE__ == $PROGRAM_NAME
  rows = Integer(ARGV.fetch(0))
  variant = (ARGV[1] || 'basic').to_sym
  csv = ImportCsvGenerator.generate(rows: rows, variant: variant)
  if ARGV[2]
    File.write(ARGV[2], csv)
    warn "wrote #{rows} rows (#{variant}) to #{ARGV[2]}"
  else
    print csv
  end
end
