# frozen_string_literal: true

# Benchmark: N+1 elimination for reference-master lookups.
#
# The row loop in ImporterController#result used to look up reference masters
# (Project / Tracker / IssueStatus / Enumeration / IssueCategory) by name on
# every row. This script measures, against a real DB, the two approaches:
#   BEFORE : per-row find_by_*        (= old code / N+1)
#   AFTER  : bulk load + hash lookup  (= preload_reference_masters)
# and prints a markdown table comparing before/after.
#
# Usage (run from the Redmine root with this plugin installed under plugins/):
#   RAILS_ENV=development bundle exec rails runner \
#     plugins/redmine_importer/test/benchmark/reference_master_lookup_benchmark.rb
#
# Measurement notes:
# - Query counts come from ActiveSupport::Notifications('sql.active_record');
#   cache hits (payload[:cached]) and SCHEMA queries are excluded.
# - Measured deliberately inside connection.uncached. A real import saves an
#   issue on every row, which invalidates the AR query cache each iteration, so
#   the per-row find_by_* calls are never served from cache and always hit the
#   DB (a genuine N+1). uncached stays faithful to that real behavior.

MASTER_TABLES = %w[projects trackers issue_statuses enumerations issue_categories].freeze
ROW_COUNTS = [50, 200, 1000].freeze

# Run the block while counting non-cached queries against the 5 master tables.
def measure(&block)
  count = 0
  subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
    payload = args.last
    next if payload[:cached]
    next if payload[:name] == 'SCHEMA'

    sql = payload[:sql].to_s
    count += 1 if MASTER_TABLES.any? { |t| sql.match?(/\b#{t}\b/) }
  end

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
  elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0

  [count, elapsed_ms]
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
end

# Build N dummy rows. Each column cycles through existing master names.
# (No Date.now / rand; values vary by index so results are reproducible.)
def build_rows(n, names)
  Array.new(n) do |i|
    {
      project: names[:project][i % names[:project].size],
      tracker: names[:tracker][i % names[:tracker].size],
      status: names[:status][i % names[:status].size],
      priority: names[:priority][i % names[:priority].size],
      category: names[:category][i % [names[:category].size, 1].max]
    }
  end
end

# BEFORE: the per-row find_by_* pattern, identical to the old code.
def run_before(rows, project_id)
  ActiveRecord::Base.connection.uncached do
    rows.each do |row|
      Project.find_by_name(row[:project])
      Tracker.find_by_name(row[:tracker])
      IssueStatus.find_by_name(row[:status])
      Enumeration.find_by_name(row[:priority])
      IssueCategory.find_by_project_id_and_name(project_id, row[:category])
    end
  end
end

# AFTER: bulk load + hash lookup, equivalent to preload_reference_masters.
def run_after(rows, project_id)
  ActiveRecord::Base.connection.uncached do
    project_by_name = {}
    Project.all.each { |p| project_by_name[p.name] ||= p }
    tracker_by_name = {}
    Tracker.all.each { |t| tracker_by_name[t.name] ||= t }
    status_by_name = {}
    IssueStatus.all.each { |s| status_by_name[s.name] ||= s }
    priority_by_name = {}
    Enumeration.all.each { |e| priority_by_name[e.name] ||= e }
    category_by_project_and_name = {}
    IssueCategory.all.each { |c| category_by_project_and_name[[c.project_id, c.name]] ||= c }

    rows.each do |row|
      project_by_name[row[:project]]
      tracker_by_name[row[:tracker]]
      status_by_name[row[:status]]
      priority_by_name[row[:priority]]
      category_by_project_and_name[[project_id, row[:category]]]
    end
  end
end

def pct(before, after)
  return 'n/a' if before.zero?

  format('%+.1f%%', (after - before) * 100.0 / before)
end

# --- Run ----------------------------------------------------------------

names = {
  project: Project.pluck(:name).compact,
  tracker: Tracker.pluck(:name).compact,
  status: IssueStatus.pluck(:name).compact,
  priority: Enumeration.pluck(:name).compact,
  category: IssueCategory.pluck(:name).compact
}

if names.values.any?(&:empty?)
  warn 'Not enough master data. Run against a DB (e.g. development) that has ' \
       'projects, trackers, statuses, priorities, and categories.'
  exit 1
end

project_id = Project.first.id

puts '## Reference-master N+1 elimination benchmark'
puts
puts "- Tables measured: #{MASTER_TABLES.join(', ')}"
puts '- BEFORE = per-row find_by_* (old code / N+1) / AFTER = bulk load + hash lookup'
puts '- Query counts exclude cache hits and SCHEMA; measured with AR query cache disabled (uncached)'
puts "- Environment: Redmine #{Redmine::VERSION} / #{ActiveRecord::Base.connection.adapter_name} / #{Rails.env}"
puts
puts '| rows | before queries | after queries | queries reduced | before ms | after ms | time reduced |'
puts '|-----:|---------------:|--------------:|----------------:|----------:|---------:|-------------:|'

ROW_COUNTS.each do |n|
  rows = build_rows(n, names)

  # Warm-up (exclude one-time costs such as connection setup and class loading).
  run_before(rows, project_id)
  run_after(rows, project_id)

  before_q, before_ms = measure { run_before(rows, project_id) }
  after_q, after_ms = measure { run_after(rows, project_id) }

  puts format('| %4d | %14d | %13d | %15s | %9.1f | %8.1f | %12s |',
              n, before_q, after_q, pct(before_q, after_q),
              before_ms, after_ms, pct(before_ms, after_ms))
end

puts
puts 'Note: after keeps a constant 5 master queries regardless of N (one bulk load ' \
     'per table), while before grows linearly as 5xN.'
