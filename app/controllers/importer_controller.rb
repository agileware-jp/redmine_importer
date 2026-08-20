# frozen_string_literal: true

require 'csv'
require 'tempfile'

MultipleIssuesForUniqueValue = Class.new(RuntimeError)
NoIssueForUniqueValue = Class.new(RuntimeError)

class ImporterController < ApplicationController
  using RedmineImporter::Patches::Redmine51ToFsMethodPatch
  before_action :find_project

  ISSUE_ATTRS = %i[id subject assigned_to fixed_version
                   author description category priority tracker status
                   start_date due_date done_ratio estimated_hours
                   parent_issue watchers is_private].freeze

  def index; end

  def match
    if params[:file].blank?
      flash[:error] = I18n.t(:flash_csv_file_is_blank)
      redirect_to action: :index
      return
    end

    # Delete existing iip to ensure there can't be two iips for a user
    ImportInProgress.where('user_id = ?', User.current.id).delete_all
    # save import-in-progress data
    iip = ImportInProgress.find_or_create_by(user_id: User.current.id)
    iip.quote_char = params[:wrapper]
    iip.col_sep = params[:splitter]
    iip.encoding = params[:encoding]
    iip.created = Time.new
    if params[:file].present?
      raw_data = params[:file].read

      validate_encoding_mismatch(raw_data, params[:encoding])
      return if flash[:error].present?
      iip.csv_data = raw_data
    end
    iip.save

    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime('%Y-%m-%d %H:%M:%S')
    @original_filename = params[:file].original_filename

    flash.delete(:error)
    validate_csv_data(iip.csv_data)
    return if flash[:error].present?

    # Check CSV row count limit
    validate_csv_row_limit(iip)
    return if flash[:error].present?

    sample_data(iip)
    return if flash[:error].present?

    set_csv_headers(iip)
    return if flash[:error].present?

    # fields
    @attrs = []
    ISSUE_ATTRS.each do |attr|
      # @attrs.push([l_has_string?("field_#{attr}".to_sym) ? l("field_#{attr}".to_sym) : attr.to_s.humanize, attr])
      @attrs.push([l_or_humanize(attr, prefix: 'field_'), "standard_field-#{attr}"])
    end
    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, "custom_field-#{cfield.name}"])
    end
    IssueRelation::TYPES.each_pair do |rtype, rinfo|
      @attrs.push([l_or_humanize(rinfo[:name]), "issue_relation-#{rtype}"])
    end
    @attrs.sort!
  end

  def result
    # used for bookkeeping
    flash.delete(:error)

    init_globals
    # Used to optimize some work that has to happen inside the loop
    unique_attr_checked = false

    # Retrieve saved import data
    iip = ImportInProgress.find_by_user_id(User.current.id)
    if iip.nil?
      flash[:error] = l(:error_no_import_in_progress)
      return
    end
    if iip.created.strftime('%Y-%m-%d %H:%M:%S') != params[:import_timestamp]
      flash[:error] = l(:error_import_superseded)
      return
    end
    # which options were turned on?
    update_issue = params[:update_issue]
    update_other_project = params[:update_other_project]
    send_emails = params[:send_emails]
    add_categories = params[:add_categories]
    add_versions = params[:add_versions]
    ignore_non_exist = params[:ignore_non_exist]

    # which fields should we use? what maps to what?
    unique_field = params[:unique_field].empty? ? nil : params[:unique_field]

    fields_map = {}
    params[:fields_map].each { |k, v| fields_map[k.unpack('U*').pack('U*')] = v }
    unique_attr = fields_map[unique_field]

    default_tracker = params[:default_tracker]
    journal_field = params[:journal_field]

    # attrs_map is fields_map's invert
    @attrs_map = fields_map.invert

    # validation!
    # if the unique_attr is blank but any of the following opts is turned on,
    if unique_attr.blank?
      if update_issue
        flash[:error] = l(:text_rmi_specify_unique_field_for_update)
      elsif @attrs_map['standard_field-parent_issue'].present?
        flash[:error] = l(:text_rmi_specify_unique_field_for_column,
                          column: l(:field_parent_issue))
      else IssueRelation::TYPES.each_key.any? { |t| @attrs_map["issue_relation-#{t}"].present? }
           IssueRelation::TYPES.each_key do |t|
             if @attrs_map["issue_relation-#{t}"].present?
               flash[:error] = l(:text_rmi_specify_unique_field_for_column,
                                 column: l("label_#{t}".to_sym))
             end
           end
      end
    end

    # validate that the id attribute has been selected
    if use_issue_id
      if @attrs_map['standard_field-id'].blank?
        flash[:error] = l(:error_must_map_id_column)
      end
    end

    # if error is full, NOP
    return if flash[:error].present?

    csv_opt = { headers: true,
                encoding: 'UTF-8',
                quote_char: iip.quote_char,
                col_sep: iip.col_sep }
    CSV.new(iip.csv_data, **csv_opt).each do |row|
      project = Project.find_by_name(fetch('standard_field-project', row))
      project ||= @project

      begin
        row.each do |k, v|
          k = k.unpack('U*').pack('U*') if k.is_a?(String)
          v = v.unpack('U*').pack('U*') if v.is_a?(String)

          row[k] = v
        end

        issue = Issue.new
        issue.notify = false

        issue.id = fetch('standard_field-id', row) if use_issue_id

        tracker = Tracker.find_by_name(fetch('standard_field-tracker', row))
        status = IssueStatus.find_by_name(fetch('standard_field-status', row))
        author = if @attrs_map.key?('standard_field-author') && @attrs_map['standard_field-author']
                   user_for_login!(fetch('standard_field-author', row))
                 else
                   User.current
                 end
        priority = Enumeration.find_by_name(fetch('standard_field-priority', row))
        category_name = fetch('standard_field-category', row)
        category = IssueCategory.find_by_project_id_and_name(project.id,
                                                             category_name)

        if !category \
          && category_name && !category_name.empty? \
          && add_categories

          category = project.issue_categories.build(name: category_name)
          category.save
        end

        if category.blank? && fetch('standard_field-category', row).present?
          @unfound_class = 'Category'
          @unfound_key = fetch('standard_field-category', row)
          raise ActiveRecord::RecordNotFound
        end

        if fetch('standard_field-assigned_to', row).present?
          assigned_to = user_for_login!(fetch('standard_field-assigned_to', row))
          assigned_to = nil if assigned_to == User.anonymous
        else
          assigned_to = nil
        end

        if fetch('standard_field-fixed_version', row).present?
          fixed_version_name = fetch('standard_field-fixed_version', row)
          fixed_version_id = version_id_for_name!(project,
                                                  fixed_version_name,
                                                  add_versions)
        else
          fixed_version_name = nil
          fixed_version_id = nil
        end

        watchers = fetch('standard_field-watchers', row)

        issue.project_id = !project.nil? ? project.id : @project.id
        issue.tracker_id = !tracker.nil? ? tracker.id : default_tracker
        issue.author_id = !author.nil? ? author.id : User.current.id
      rescue ActiveRecord::RecordNotFound
        log_failure(row, l(:warning_record_not_found, issue_num: @failed_count + 1,
                                                              class_name: @unfound_class, key: @unfound_key))
        next
      end

      begin
        unique_attr = translate_unique_attr(issue, unique_field, unique_attr, unique_attr_checked)

        issue, journal = handle_issue_update(issue, row, author, status, update_other_project, journal_field,
                                             unique_attr, unique_field, ignore_non_exist, update_issue)

        project ||= Project.find_by_id(issue.project_id)

        update_project_issues_stat(project)
        assign_issue_attrs(issue, category, fixed_version_id, assigned_to, status, row, priority, tracker)
        handle_parent_issues(issue, row, ignore_non_exist, unique_attr, unique_field)
        handle_custom_fields(add_versions, issue, project, row)
        handle_watchers(issue, row, watchers)
      rescue RowFailed
        next
      rescue ActiveRecord::RecordNotFound
        log_failure(row, l(:warning_record_not_found, issue_num: @failed_count + 1,
                                                      class_name: @unfound_class, key: @unfound_key))
        next
      rescue ArgumentError
        log_failure(row, l(:warning_invalid_value, issue_num: @failed_count + 1, value: @error_value))
        next
      rescue NoMethodError => e
        log_no_method_failure(row, e)
        next
      end

      issue.singleton_class.include RedmineImporter::Concerns::ValidateStatus

      begin
        issue_saved = issue.save
      rescue ActiveRecord::RecordNotUnique
        issue_saved = false
        @messages << l(:error_issue_id_taken)
      rescue NoMethodError => e
        log_no_method_failure(row, e)
        next
      end

      if issue_saved
        @issue_by_unique_attr[row[unique_field]] = issue if unique_field
        @deferred_callbacks.execute(row[unique_field], issue) if unique_field

        if send_emails
          if update_issue
            if Setting.notified_events.include?('issue_updated') \
               && !(issue.current_journal.details.empty? && issue.current_journal.notes.blank?)

              Mailer.deliver_issue_edit(issue.current_journal)
            end
          else
            if Setting.notified_events.include?('issue_added')
              Mailer.deliver_issue_add(issue)
            end
          end
        end

        # Issue relations
        IssueRelation::TYPES.each_pair do |rtype, _rinfo|
          other_value = row[@attrs_map["issue_relation-#{rtype}"]]
          next if other_value.blank?

          begin
            # When unique_attr is 'standard_field-id' and use_issue_id is false,
            # use cache-based lookup to support deferred reference resolution.
            if unique_attr == 'standard_field-id' && !use_issue_id
              other_issue = @issue_by_unique_attr[other_value]
              unless other_issue
                # Target not in cache yet - register callback for deferred creation
                @deferred_callbacks.register(other_value, :add_relation, row[unique_field], rtype)
                next
              end
            else
              other_issue = issue_for_unique_attr(unique_attr, other_value, row)
            end

            already_related = issue.relations.any? do |r|
              (r.other_issue(issue).id == other_issue.id) \
                && (r.relation_type_for(issue) == rtype)
            end
            next if already_related

            relation = IssueRelation.new(issue_from: issue,
                                         issue_to: other_issue,
                                         relation_type: rtype)
            unless relation.save
              @messages << "Warning: Failed to create relation: #{relation.errors.full_messages.join(', ')}"
            end
          rescue NoIssueForUniqueValue
            # Register callback for deferred relation creation
            # Target issue may appear later in CSV
            @deferred_callbacks.register(other_value, :add_relation, row[unique_field], rtype)
          rescue MultipleIssuesForUniqueValue
            @messages << "Warning: Multiple matches for relation target '#{other_value}'"
          end
        end

        journal

        @handle_count += 1

      else
        @failed_count += 1
        @failed_issues[@failed_count] = row
        @messages << l(:warning_validation_errors, issue_num: @failed_count)
        issue.errors.each do |attr, error_message|
          @messages << l(:warning_attr_error, attr: attr, message: error_message)
        end
      end
    end # do

    # Warn about any unresolved deferred references
    @deferred_callbacks.warn_unresolved

    unless @failed_issues.empty?
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers
    end

    # Clean up after ourselves
    iip.delete

    # Garbage prevention: clean up iips older than 3 days
    ImportInProgress.where('created < ?', Time.new - 3 * 24 * 60 * 60).delete_all

    if use_issue_id && ActiveRecord::Base.connection.respond_to?(:reset_pk_sequence!)
      ActiveRecord::Base.connection.reset_pk_sequence!(Issue.table_name)
    end
  end

  def translate_unique_attr(issue, unique_field, unique_attr, unique_attr_checked)
    # translate unique_attr if it's a custom field -- only on the first issue
    unless unique_attr_checked
      if unique_field && !ISSUE_ATTRS.include?(unique_attr.to_sym)
        issue.available_custom_fields.each do |cf|
          if cf.name == unique_attr
            unique_attr = "cf_#{cf.id}"
            break
          end
        end
      end
      unique_attr_checked = true
    end
    unique_attr
  end

  def handle_issue_update(issue, row, author, status, update_other_project, journal_field, unique_attr, unique_field, ignore_non_exist, update_issue)
    if update_issue
      begin
        issue = issue_for_unique_attr(unique_attr, row[unique_field], row)

        # ignore other project's issue or not
        if issue.project_id != @project.id && !update_other_project
          @skip_count += 1
          raise RowFailed
        end

        # ignore closed issue except reopen
        if issue.status.is_closed?
          if status.nil? || status.is_closed?
            @skip_count += 1
            raise RowFailed
          end
        end

        # init journal
        note = row[journal_field] || ''
        journal = issue.init_journal(author || User.current,
                                     note || '')
        journal.notify = false # disable journal's notification to use custom one down below
        @update_count += 1
      rescue NoIssueForUniqueValue
        if ignore_non_exist
          @skip_count += 1
          raise RowFailed
        else
          log_failure(row,
                      l(:warning_no_match_for_update, issue_num: @failed_count + 1,
                                                      value: row[unique_field]))
          raise RowFailed
        end
      rescue MultipleIssuesForUniqueValue
        log_failure(row,
                    l(:warning_multiple_matches_for_update, issue_num: @failed_count + 1,
                                                            value: row[unique_field]))
        raise RowFailed
      end
    end
    [issue, journal]
  end

  def update_project_issues_stat(project)
    if @affect_projects_issues.key?(project.name)
      @affect_projects_issues[project.name] += 1
    else
      @affect_projects_issues[project.name] = 1
    end
  end

  def assign_issue_attrs(issue, category, fixed_version_id, assigned_to, status, row, priority, tracker)
    # required attributes
    if assignable?(:status)
      issue.status_id = !status.nil? ? status.id : issue.status_id
    end
    if assignable?(:priority)
      issue.priority_id = !priority.nil? ? priority.id : issue.priority_id
    end
    if assignable?(:subject)
      issue.subject = fetch('standard_field-subject', row) || issue.subject
    end
    if assignable?(:tracker)
      issue.tracker_id = tracker.present? ? tracker.id : issue.tracker_id
    end

    # optional attributes
    issue.description = fetch('standard_field-description', row) if assignable?(:description)
    issue.category_id = category.try(:id) if assignable?(:category)

    %w[start_date due_date].each do |date_field_name|
      next unless assignable?(date_field_name)

      date_field_value = fetch("standard_field-#{date_field_name}", row)

      if date_field_value.present?
        begin
          issue.send("#{date_field_name}=", Date.parse(date_field_value))
        rescue ArgumentError
          @error_value = date_field_value
          raise ArgumentError
        end
      else
        issue.send("#{date_field_name}=", nil)
      end
    end

    if assignable?(:assigned_to)
      issue.assigned_to_id = assigned_to.try(:id)
      unless issue.assigned_to.in?(issue.assignable_users)
        issue.assigned_to = nil
      end
    end
    issue.fixed_version_id = fixed_version_id if assignable?(:fixed_version)
    issue.done_ratio = fetch('standard_field-done_ratio', row) if assignable?(:done_ratio)
    if assignable?(:estimated_hours)
      issue.estimated_hours = fetch('standard_field-estimated_hours', row)
    end
    if assignable?(:is_private)
      issue.is_private = (convert_to_boolean(fetch('standard_field-is_private', row)) || false)
    end
  end

  def assignable?(field)
    raise unless ISSUE_ATTRS.include?(field.to_sym)

    @attrs_map.key?("standard_field-#{field}")
  end

  def handle_parent_issues(issue, row, ignore_non_exist, unique_attr, unique_field)
    return unless assignable?(:parent_issue)

    parent_value = fetch('standard_field-parent_issue', row)
    return unless parent_value.present?

    # When unique_attr is 'standard_field-id' and use_issue_id is false,
    # the # column is used only for CSV-internal references.
    # Use cache-based lookup to support deferred reference resolution.
    if unique_attr == 'standard_field-id' && !use_issue_id
      if cached_parent = @issue_by_unique_attr[parent_value]
        issue.parent_issue_id = cached_parent.id
      else
        # Parent not in cache yet - register callback for deferred assignment
        @deferred_callbacks.register(parent_value, :set_parent, row[unique_field])
      end
      return
    end

    # Standard lookup via issue_for_unique_attr
    issue.parent_issue_id = issue_for_unique_attr(unique_attr, parent_value, row).id
  rescue NoIssueForUniqueValue
    # Register callback for deferred parent assignment
    # Parent issue may appear later in CSV
    @deferred_callbacks.register(parent_value, :set_parent, row[unique_field])
  rescue MultipleIssuesForUniqueValue
    @failed_count += 1
    @failed_issues[@failed_count] = row
    @messages << l(:warning_parent_multiple_matches, issue_num: @failed_count, value: parent_value)
    raise RowFailed
  end

  def init_globals
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_issues = {}
    @messages = []
    @affect_projects_issues = {}
    # This is a cache of previously inserted issues indexed by the value
    # the user provided in the unique column
    @issue_by_unique_attr = {}
    # Cache of user id by login
    @user_by_login = {}
    # Cache of Version by name
    @version_id_by_name = {}
    # Cache of CustomFieldEnumeration by name
    @enumeration_id_by_name = {}
    # Deferred callbacks for resolving forward references in CSV
    @deferred_callbacks = RedmineImporter::DeferredCallbacks.new(
      issue_cache: @issue_by_unique_attr,
      messages: @messages
    )
  end

  def handle_watchers(issue, row, watchers)
    return unless assignable?(:watchers)

    watcher_failed_count = 0
    if watchers
      assignable_watcher_users = issue.project.principals.assignable_watchers
      watchers.split(',').each do |watcher|
        begin
          watcher_user = user_for_login!(watcher)
          next if issue.watcher_users.include?(watcher_user)

          unless assignable_watcher_users.include?(watcher_user) && issue.valid_watcher?(watcher_user)
            raise ActiveRecord::RecordNotFound
          end

          issue.add_watcher(watcher_user)
        rescue ActiveRecord::RecordNotFound
          if watcher_failed_count == 0
            @failed_count += 1
            @failed_issues[@failed_count] = row
          end
          watcher_failed_count += 1
          @messages << l(:warning_watcher_not_found, issue_num: @failed_count, login: watcher)
        end
      end
    end
    raise RowFailed if watcher_failed_count > 0
  end

  def handle_custom_fields(add_versions, issue, project, row)
    custom_failed_count = 0
    issue.custom_field_values = issue.available_custom_fields.each_with_object({}) do |cf, h|
      next h unless @attrs_map.key?("custom_field-#{cf.name}") # this cf is absent or ignored.

      value = row[@attrs_map["custom_field-#{cf.name}"]]
      if cf.multiple
        h[cf.id] = process_multivalue_custom_field(project, add_versions, issue, cf, value)
      else
        begin
          if value.present?
            value = case cf.field_format
                    when 'user'
                      user = user_id_for_login!(value)
                      if user.in?(cf.format.possible_values_records(cf, issue).map(&:id))
                        user == User.anonymous.id ? nil : user.to_s
                      end
                    when 'version'
                      version_id_for_name!(project, value, add_versions).to_s
                    when 'date'
                      value.to_date.to_fs(:db)
                    when 'bool'
                      convert_to_0_or_1(value)
                    when 'enumeration'
                      enumeration_id_for_name!(cf, value).to_s
                    else
                      value
                    end
          else
            value = nil
          end

          h[cf.id] = value
        rescue StandardError
          if custom_failed_count == 0
            custom_failed_count += 1
            @failed_count += 1
            @failed_issues[@failed_count] = row
          end
          @messages << l(:warning_custom_field_invalid, field_name: cf.name,
                                                            issue_num: @failed_count, value: value)
        end
      end
    end
    raise RowFailed if custom_failed_count > 0
  end

  private

  def use_issue_id
    params[:use_issue_id].present?
  end

  def fetch(key, row)
    row[@attrs_map[key]]
  end

  def log_failure(row, msg)
    @failed_count += 1
    @failed_issues[@failed_count] = row
    @messages << msg
  end

  def log_no_method_failure(row, error)
    log_failure(row, l(:warning_validation_errors, issue_num: @failed_count + 1))
    @messages << l(:warning_attr_error, attr: error.class.name, message: error.message)
  end

  def find_project
    @project = Project.find(params[:project_id])
  end

  def flash_message(type, text)
    flash[type] ||= ''
    flash[type] += "#{text}<br/>"
  end

  def validate_encoding_mismatch(raw_data, encoding)
    return if encoding == 'N'  # NKF auto-detect, skip validation

    source_encoding = { 'U' => 'UTF-8', 'S' => 'Shift_JIS', 'EUC' => 'EUC-JP' }[encoding]
    return if source_encoding.nil?

    unless raw_data.dup.force_encoding(source_encoding).valid_encoding?
      flash[:error] = l(:error_encoding_mismatch)
      redirect_to project_importer_path(project_id: @project)
    end
  end

  def validate_csv_data(csv_data)
    if csv_data.lines.to_a.size <= 1
      flash[:error] = l(:error_csv_no_data) +
        '<br/><br/>Header :<br/>'.html_safe + csv_data.encode('UTF-8', invalid: :replace, undef: :replace)

      redirect_to project_importer_path(project_id: @project)

      nil
    end
  end

  def validate_csv_row_limit(iip)
    max_rows = Setting.plugin_redmine_importer['max_csv_rows'].to_i
    max_rows = 5000 if max_rows <= 0 # Default fallback

    # Count actual data rows using CSV parser (excluding header)
    row_count = 0
    begin
      CSV.new(iip.csv_data, headers: true,
                           encoding: 'UTF-8',
                           quote_char: iip.quote_char,
                           col_sep: iip.col_sep).each do
        row_count += 1
      end
    rescue StandardError => e
      # If CSV parsing fails, fall back to line counting
      row_count = iip.csv_data.lines.to_a.size - 1
    end

    if row_count > max_rows
      flash[:error] = I18n.t(:error_csv_row_limit_exceeded,
                            max_rows: max_rows,
                            actual_rows: row_count)
      redirect_to project_importer_path(project_id: @project)
    end
  end

  def sample_data(iip)
    # display sample
    sample_count = 5
    @samples = []

    begin
      CSV.new(iip.csv_data, headers: true,
                            encoding: 'UTF-8',
                            quote_char: iip.quote_char,
                            col_sep: iip.col_sep).each_with_index do |row, i|
        @samples[i] = row
        break if i >= sample_count
      end # do
    rescue Exception => e
      csv_data_lines = iip.csv_data.lines.to_a

      error_message = e.message +
                      '<br/><br/>Header :<br/>'.html_safe +
                      csv_data_lines[0].to_s.encode('UTF-8', invalid: :replace, undef: :replace)

      # if there was an exception, probably happened on line after the last sampled.
      unless csv_data_lines.empty?
        error_message += '<br/><br/>Error on header or line :<br/>'.html_safe +
                         csv_data_lines[@samples.size + 1].to_s.encode('UTF-8', invalid: :replace, undef: :replace)
      end

      flash[:error] = error_message

      redirect_to project_importer_path(project_id: @project)

      nil
    end
  end

  def set_csv_headers(iip)
    @headers = @samples[0].headers unless @samples.empty?

    missing_header_columns = ''
    @headers.each_with_index do |h, i|
      missing_header_columns += " #{i + 1}" if h.nil?
    end

    if missing_header_columns.present?
      flash[:error] = l(:error_csv_missing_headers, columns: missing_header_columns, total: @headers.size) +
        '<br/><br/>Header :<br/>'.html_safe + iip.csv_data.lines.to_a[0].to_s.encode('UTF-8', invalid: :replace, undef: :replace)

      redirect_to project_importer_path(project_id: @project)

      nil
    end
  end

  # Returns the issue object associated with the given value of the given attribute.
  # Raises NoIssueForUniqueValue if not found or MultipleIssuesForUniqueValue
  def issue_for_unique_attr(unique_attr, attr_value, row_data)
    if @issue_by_unique_attr.key?(attr_value)
      return @issue_by_unique_attr[attr_value]
    end

    if use_issue_id && unique_attr == 'standard_field-id'
      issues = [Issue.find_by_id(attr_value)].compact
    else
      # Use IssueQuery class Redmine >= 2.3.0
      begin
        if Module.const_get('IssueQuery') && IssueQuery.is_a?(Class)
          query_class = IssueQuery
        end
      rescue NameError
        query_class = Query
      end

      query = query_class.new(name: '_importer', project: @project)
      query.add_filter('status_id', '*', [1])
      query.add_filter(unique_attr, '=', [attr_value])

      issues = Issue.joins([:project])
                    .includes(%i[assigned_to status tracker project priority
                                 category fixed_version])
                    .limit(2)
                    .where(query.statement)
    end

    if issues.size > 1
      @failed_count += 1
      @failed_issues[@failed_count] = row_data
      @messages << l(:warning_duplicate_unique_value, attr: unique_attr, value: attr_value,
                                                        issue_num: @failed_count)
      raise MultipleIssuesForUniqueValue, "Unique field #{unique_attr} with" \
        " value '#{attr_value}' has duplicate record"
    elsif issues.empty? || issues[0].nil?
      raise NoIssueForUniqueValue, "No issue with #{unique_attr} of '#{attr_value}' found"
    else
      issues.first
    end
  end

  # Returns the user matching the given keyword or raises RecordNotFound
  # Matches by login, mail, firstname+lastname, or display name
  # Implements a cache of users based on the keyword
  def user_for_login!(login)
    return @user_by_login[login] if @user_by_login.key?(login)

    begin
      # Load all users once and cache them for the entire import session
      @all_users ||= User.includes(:email_address).to_a

      user = Principal.detect_by_keyword(@all_users, login)

      if user.nil?
        raise ActiveRecord::RecordNotFound
      end

      @user_by_login[login] = user
    rescue ActiveRecord::RecordNotFound
      if params[:use_anonymous]
        @user_by_login[login] = User.anonymous
      else
        @unfound_class = 'User'
        @unfound_key = login
        raise
      end
    end

    @user_by_login[login]
  end

  def user_id_for_login!(login)
    user = user_for_login!(login)
    user ? user.id : nil
  end

  # Returns the id for the given version or raises RecordNotFound.
  # Implements a cache of version ids based on version name
  # If add_versions is true and a valid name is given,
  # will create a new version and save it when it doesn't exist yet.
  def version_id_for_name!(project, name, add_versions)
    unless @version_id_by_name.key?(name)
      version = project.shared_versions.find_by_name(name)
      unless version
        if name && !name.empty? && add_versions
          version = project.versions.build(name: name)
          version.save
        else
          @unfound_class = 'Version'
          @unfound_key = name
          raise ActiveRecord::RecordNotFound, "No version named #{name}"
        end
      end
      @version_id_by_name[name] = version.id
    end
    @version_id_by_name[name]
  end

  def enumeration_id_for_name!(custom_field, name)
    unless @enumeration_id_by_name.key?(name)
      enumeration = custom_field.enumerations.find_by(name: name).try!(:id)
      if enumeration.nil?
        @unfound_class = 'CustomFieldEnumeration'
        @unfound_key = name
        raise ActiveRecord::RecordNotFound, "No enumeration named #{name}"
      end
      @enumeration_id_by_name[name] = enumeration
    end
    @enumeration_id_by_name[name]
  end

  def process_multivalue_custom_field(project, add_versions, issue, custom_field, csv_val)
    return [] if csv_val.blank?

    csv_val.split(',').map(&:strip).map do |val|
      if custom_field.field_format == 'version'
        version = version_id_for_name!(project, val, add_versions)
        version
      elsif custom_field.field_format == 'enumeration'
        enumeration_id_for_name!(custom_field, val)
      elsif custom_field.field_format == 'user'
        user = user_id_for_login!(val)
        if user.in?(custom_field.format.possible_values_records(custom_field, issue).map(&:id))
          user == User.anonymous.id ? nil : user.to_s
        end
      else
        val
      end
    end
  end

  def convert_to_boolean(raw_value)
    return_value_by raw_value, true, false
  end

  def convert_to_0_or_1(raw_value)
    return_value_by raw_value, '1', '0'
  end

  def return_value_by(raw_value, value_yes, value_no)
    case raw_value
    when I18n.t('general_text_yes')
      value_yes
    when I18n.t('general_text_no')
      value_no
    end
  end

  class RowFailed < RuntimeError
  end
end
