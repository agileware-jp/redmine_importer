# frozen_string_literal: true

# Benchmark for the batched import flow (POST result -> repeated POST run)
# with large CSV files. The number to watch is max_req_s: with the batch
# design no single request may exceed the 10-second budget.
#
# This file lives outside test/{unit,functional,integration,system} on
# purpose: `rake redmine:plugins:test` and CI must not pick it up. Run it
# explicitly from the Redmine root:
#
#   bundle exec ruby -Itest plugins/redmine_importer/test/performance/import_benchmark_test.rb
#
# Row counts and variants can be overridden via environment variables:
#
#   BENCH_ROWS=100,500 BENCH_VARIANTS=basic,full bundle exec ruby -Itest ...
#
# No thresholds are asserted (numbers vary by machine); the output is the
# deliverable.
#
# Reference numbers (arm64 mac, PostgreSQL, 2026-08): full/5000 finishes in
# ~5 minutes total with max_req_s < 1s; the pre-batching implementation
# needed 85s for a single basic/5000 request and never finished full/5000.
require File.expand_path('../test_helper', __dir__)
require_relative 'generate_import_csv'

$stdout.sync = true

class ImportBenchmarkTest < ActionController::TestCase
  tests ImporterController

  fixtures :users

  ROW_COUNTS = ENV.fetch('BENCH_ROWS', '500,1000,5000').split(',').map { |s| Integer(s.strip) }
  VARIANTS = ENV.fetch('BENCH_VARIANTS', 'basic,full').split(',').map { |s| s.strip.to_sym }

  def setup
    ActionController::Base.allow_forgery_protection = false
    @project = Project.create! name: 'bench', identifier: 'import-benchmark-test'
    @tracker = Tracker.new(name: 'Defect')
    @tracker.default_status = IssueStatus.find_or_create_by!(name: 'New')
    @tracker.save!
    @project.trackers << @tracker
    @project.save!
    @project.enable_module!(:importer)
    IssuePriority.find_or_create_by!(name: 'Critical')
    @role = Role.create! name: 'BENCH', permissions: %i[import view_issues]
    @user = create_user!(@role, @project)
    create_tags_field!(@project, @tracker)
    User.stubs(:current).returns(@user)
  end

  test 'benchmark batched import flow' do
    puts
    puts "Batched import benchmark (plugin v#{Redmine::Plugin.find(:redmine_importer).version})"
    puts format('%-14s %8s %9s %9s %10s %10s %12s %8s',
                'variant', 'rows', 'requests', 'total_s', 'max_req_s', 'avg_req_s', 'queries', 'created')

    VARIANTS.each do |variant|
      ROW_COUNTS.each do |rows|
        iip = create_iip!(ImportCsvGenerator.generate(rows: rows, variant: variant))
        issues_before = Issue.count
        GC.start

        post :result, params: bench_params(iip, variant)
        assert_response :redirect

        request_times = []
        total_queries = 0
        loop do
          elapsed, queries = measure do
            post :run, params: { project_id: @project.identifier }
          end
          request_times << elapsed
          total_queries += queries
          break unless response.redirect_url&.include?('/importer/run')
          raise 'import did not converge' if request_times.size > rows + 10
        end

        created = Issue.count - issues_before
        assert_equal rows, created, "expected #{rows} issues to be created for #{variant}/#{rows}"
        puts format('%-14s %8d %9d %9.2f %10.3f %10.3f %12d %8d',
                    variant, rows, request_times.size, request_times.sum,
                    request_times.max, request_times.sum / request_times.size,
                    total_queries, created)
      end
    end
  end

  private

  def measure
    queries = 0
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      queries += 1 unless payload[:name] == 'SCHEMA' || payload[:cached]
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    [Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, queries]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def bench_params(iip, variant)
    fields_map = {
      '#' => 'standard_field-id',
      'Subject' => 'standard_field-subject',
      'Description' => 'standard_field-description',
      'Priority' => 'standard_field-priority',
      'Tracker' => 'standard_field-tracker',
      'Status' => 'standard_field-status'
    }
    fields_map['Tags'] = 'custom_field-Tags' if %i[custom_fields full].include?(variant)
    fields_map['Parent'] = 'standard_field-parent_issue' if %i[parent full].include?(variant)

    {
      import_timestamp: iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.identifier,
      fields_map: fields_map
    }
  end

  def create_iip!(csv_data)
    ImportInProgress.where(user_id: @user.id).delete_all
    iip = ImportInProgress.new
    iip.user = @user
    iip.project = @project
    iip.csv_data = csv_data
    iip.created = DateTime.now
    iip.encoding = 'UTF-8'
    iip.col_sep = ','
    iip.quote_char = '"'
    iip.save!
    iip
  end

  def create_user!(role, project)
    user = User.new admin: true,
                    firstname: 'Bench',
                    lastname: 'User',
                    mail: 'bench.user@example.com'
    user.login = 'bench'
    membership = user.memberships.build(project: project)
    membership.roles << role
    membership.principal = user
    user.pref.auto_watch_on = nil if Redmine::VERSION.to_s.to_f >= 5.1
    user.save!
    user
  end

  def create_tags_field!(project, tracker)
    field = IssueCustomField.new name: 'Tags', multiple: true, field_format: 'list'
    field.projects << project
    field.possible_values = %w[tag1 tag2]
    field.save!
    tracker.custom_fields << field
    tracker.save!
    field
  end
end
