require 'csv'
require 'tempfile'

MultipleIssuesForUniqueValue = Class.new(Exception)
NoIssueForUniqueValue = Class.new(Exception)

class ImporterController < ApplicationController
  unloadable

  before_filter :find_project

  ISSUE_ATTRS = [:id, :subject, :assigned_to, :fixed_version,
                 :author, :description, :category, :priority, :tracker, :status,
                 :start_date, :due_date, :done_ratio, :estimated_hours,
                 :parent_issue, :watchers, :is_private ]

  def index; end


  def match
    if params[:file].blank?
      flash[:error] = I18n.t(:flash_csv_file_is_blank)
      redirect_to action: :index
      return
    end

    # Delete existing iip to ensure there can't be two iips for a user
    ImportInProgress.delete_all(["user_id = ?",User.current.id])
    # save import-in-progress data
    iip = ImportInProgress.find_or_create_by(user_id: User.current.id)
    iip.quote_char = params[:wrapper]
    iip.col_sep = params[:splitter]
    iip.encoding = params[:encoding]
    iip.created = Time.new
    iip.csv_data = params[:file].read unless params[:file].blank?
    iip.save

    # Put the timestamp in the params to detect
    # users with two imports in progress
    @import_timestamp = iip.created.strftime("%Y-%m-%d %H:%M:%S")
    @original_filename = params[:file].original_filename

    flash.delete(:error)
    validate_csv_data(iip.csv_data)
    return if flash[:error].present?

    sample_data(iip)
    return if flash[:error].present?

    set_csv_headers(iip)
    return if flash[:error].present?


    # fields
    @attrs = Array.new
    ISSUE_ATTRS.each do |attr|
      #@attrs.push([l_has_string?("field_#{attr}".to_sym) ? l("field_#{attr}".to_sym) : attr.to_s.humanize, attr])
      @attrs.push([l_or_humanize(attr, :prefix=>"field_"), attr])
    end
    @project.all_issue_custom_fields.each do |cfield|
      @attrs.push([cfield.name, cfield.name])
    end
    IssueRelation::TYPES.each_pair do |rtype, rinfo|
      @attrs.push([l_or_humanize(rinfo[:name]),rtype])
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
    if iip == nil
      flash[:error] = "No import is currently in progress"
      return
    end
    if iip.created.strftime("%Y-%m-%d %H:%M:%S") != params[:import_timestamp]
      flash[:error] = "You seem to have started another import " \
        "since starting this one. " \
        "This import cannot be completed"
      return
    end
    # which options were turned on?
    update_issue = params[:update_issue]
    update_other_project = params[:update_other_project]
    send_emails = params[:send_emails]
    add_categories = params[:add_categories]
    add_versions = params[:add_versions]
    use_issue_id = params[:use_issue_id].present? ? true : false
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
      elsif @attrs_map["parent_issue"].present?
        flash[:error] = l(:text_rmi_specify_unique_field_for_column,
                          :column => l(:field_parent_issue))
      else IssueRelation::TYPES.each_key.any? { |t| @attrs_map[t].present? }
        IssueRelation::TYPES.each_key do |t|
          if @attrs_map[t].present?
            flash[:error] = l(:text_rmi_specify_unique_field_for_column,
                              :column => l("label_#{t}".to_sym))
          end
        end
      end
    end

    # validate that the id attribute has been selected
    if use_issue_id
      if @attrs_map["id"].blank?
        flash[:error] = "You must specify a column mapping for id" \
          " when importing using provided issue ids."
      end
    end

    # if error is full, NOP
    return if flash[:error].present?


    csv_opt = {:headers=>true,
               :encoding=>iip.encoding,
               :quote_char=>iip.quote_char,
               :col_sep=>iip.col_sep}
    CSV.new(iip.csv_data, csv_opt).each do |row|
      project = Project.find_by_name(fetch("project", row))
      project ||= @project

      begin
        row.each do |k, v|
          k = k.unpack('U*').pack('U*') if k.kind_of?(String)
          v = v.unpack('U*').pack('U*') if v.kind_of?(String)

          row[k] = v
        end

        issue = Issue.new
        issue.notify = false

        if use_issue_id
          issue.id = fetch("id", row)
        end

        tracker = Tracker.find_by_name(fetch("tracker", row))
        status = IssueStatus.find_by_name(fetch("status", row))
        author = if @attrs_map["author"]
                   user_for_login!(fetch("author", row))
                 else
                   User.current
                 end
        priority = Enumeration.find_by_name(fetch("priority", row))
        category_name = fetch("category", row)
        category = IssueCategory.find_by_project_id_and_name(project.id,
                                                             category_name)

        if (!category) \
          && category_name && category_name.length > 0 \
          && add_categories

          category = project.issue_categories.build(:name => category_name)
          category.save
        end

        if category.blank? && fetch("category", row).present?
          @unfound_class = "Category"
          @unfound_key = fetch("category", row)
          raise ActiveRecord::RecordNotFound
        end

        if fetch("assigned_to", row).present?
          assigned_to = user_for_login!(fetch("assigned_to", row))
          assigned_to = nil if assigned_to == User.anonymous
        else
          assigned_to = nil
        end

        if fetch("fixed_version", row).present?
          fixed_version_name = fetch("fixed_version", row)
          fixed_version_id = version_id_for_name!(project,
                                                  fixed_version_name,
                                                  add_versions)
        else
          fixed_version_name = nil
          fixed_version_id = nil
        end

        watchers = fetch("watchers", row)

        issue.project_id = project != nil ? project.id : @project.id
        issue.tracker_id = tracker != nil ? tracker.id : default_tracker
        issue.author_id = author != nil ? author.id : User.current.id
      rescue ActiveRecord::RecordNotFound
        log_failure(row, "Warning: When adding issue #{@failed_count+1} below," \
                    " the #{@unfound_class} #{@unfound_key} was not found")
        next
      end

      begin
        unique_attr = translate_unique_attr(issue, unique_field, unique_attr, unique_attr_checked)

        issue, journal = handle_issue_update(issue, row, author, status, update_other_project, journal_field,
                                             unique_attr, unique_field, ignore_non_exist, update_issue)

        project ||= Project.find_by_id(issue.project_id)

        update_project_issues_stat(project)
        assign_issue_attrs(issue, category, fixed_version_id, assigned_to, status, row, priority, tracker)
        handle_parent_issues(issue, row, ignore_non_exist, unique_attr)
        handle_custom_fields(add_versions, issue, project, row)
        handle_watchers(issue, row, watchers)
      rescue RowFailed
        next
      rescue ActiveRecord::RecordNotFound
        log_failure(row, "Warning: When adding issue #{@failed_count+1} below," \
                    " the #{@unfound_class} #{@unfound_key} was not found")
        next
      rescue ArgumentError
        log_failure(row, "Warning: When adding issue #{@failed_count+1} below," \
                    " #{@error_value} is not valid value.")
        next
      end

      begin
        issue_saved = issue.save
      rescue ActiveRecord::RecordNotUnique
        issue_saved = false
        @messages << "This issue id has already been taken."
      end

      unless issue_saved
        @failed_count += 1
        @failed_issues[@failed_count] = row
        @messages << "Warning: The following data-validation errors occurred" \
          " on issue #{@failed_count} in the list below"
        issue.errors.each do |attr, error_message|
          @messages << "Error: #{attr} #{error_message}"
        end
      else
        if unique_field
          @issue_by_unique_attr[row[unique_field]] = issue
        end

        if send_emails
          if update_issue
            if Setting.notified_events.include?('issue_updated') \
               && (!(issue.current_journal.details.empty? && issue.current_journal.notes.blank?))

              Mailer.deliver_issue_edit(issue.current_journal)
            end
          else
            if Setting.notified_events.include?('issue_added')
              Mailer.deliver_issue_add(issue)
            end
          end
        end

        # Issue relations
        begin
          IssueRelation::TYPES.each_pair do |rtype, rinfo|
            if !row[@attrs_map[rtype]]
              next
            end
            other_issue = issue_for_unique_attr(unique_attr,
                                                row[@attrs_map[rtype]],
                                                row)
            relations = issue.relations.select do |r|
              (r.other_issue(issue).id == other_issue.id) \
                && (r.relation_type_for(issue) == rtype)
            end
            if relations.length == 0
              relation = IssueRelation.new(:issue_from => issue,
                                           :issue_to => other_issue,
                                           :relation_type => rtype)
              relation.save
            end
          end
        rescue NoIssueForUniqueValue
          if ignore_non_exist
            @skip_count += 1
            next
          end
        rescue MultipleIssuesForUniqueValue
          break
        end

        if journal
          journal
        end

        @handle_count += 1

      end

    end # do

    if @failed_issues.size > 0
      @failed_issues = @failed_issues.sort
      @headers = @failed_issues[0][1].headers
    end

    # Clean up after ourselves
    iip.delete

    # Garbage prevention: clean up iips older than 3 days
    ImportInProgress.delete_all(["created < ?",Time.new - 3*24*60*60])

    if use_issue_id && ActiveRecord::Base.connection.respond_to?(:reset_pk_sequence!)
      ActiveRecord::Base.connection.reset_pk_sequence!(Issue.table_name)
    end
  end

  def translate_unique_attr(issue, unique_field, unique_attr, unique_attr_checked)
    # translate unique_attr if it's a custom field -- only on the first issue
    if !unique_attr_checked
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
          if status == nil || status.is_closed?
            @skip_count += 1
            raise RowFailed
          end
        end

        # init journal
        note = row[journal_field] || ''
        journal = issue.init_journal(author || User.current,
                                     note || '')
        journal.notify = false #disable journal's notification to use custom one down below
        @update_count += 1

      rescue NoIssueForUniqueValue
        if ignore_non_exist
          @skip_count += 1
          raise RowFailed
        else
          log_failure(row,
                      "Warning: Could not update issue #{@failed_count+1} below," \
                        " no match for the value #{row[unique_field]} were found")
          raise RowFailed
        end

      rescue MultipleIssuesForUniqueValue
        log_failure(row,
                    "Warning: Could not update issue #{@failed_count+1} below," \
                      " multiple matches for the value #{row[unique_field]} were found")
        raise RowFailed
      end
    end
    return issue, journal
  end

  def update_project_issues_stat(project)
    if @affect_projects_issues.has_key?(project.name)
      @affect_projects_issues[project.name] += 1
    else
      @affect_projects_issues[project.name] = 1
    end
  end

  def assign_issue_attrs(issue, category, fixed_version_id, assigned_to, status, row, priority, tracker)
    # required attributes
    issue.status_id = status != nil ? status.id : issue.status_id
    issue.priority_id = priority != nil ? priority.id : issue.priority_id
    issue.subject = fetch("subject", row) || issue.subject
    issue.tracker_id = tracker.present? ? tracker.id : issue.tracker_id

    # optional attributes
    issue.description = fetch("description", row)
    issue.category_id = category.try(:id)

    ["start_date", "due_date"].each do |date_field_name|
      date_field_value = fetch(date_field_name, row)

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

    issue.assigned_to_id = assigned_to.try(:id)
    issue.assigned_to = nil unless issue.assigned_to.in?(issue.assignable_users)
    issue.fixed_version_id = fixed_version_id
    issue.done_ratio = fetch("done_ratio", row)
    issue.estimated_hours = fetch("estimated_hours", row)
    issue.is_private = (convert_to_boolean(fetch("is_private", row)) || false)
  end

  def handle_parent_issues(issue, row, ignore_non_exist, unique_attr)
    begin
      parent_value = fetch("parent_issue", row)
      if parent_value.present?
        issue.parent_issue_id = issue_for_unique_attr(unique_attr, parent_value, row).id
      else
        issue.parent_issue_id = nil
      end
    rescue NoIssueForUniqueValue
      if ignore_non_exist
        @skip_count += 1
      else
        @failed_count += 1
        @failed_issues[@failed_count] = row
        @messages << "Warning: When setting the parent for issue #{@failed_count} below,"\
            " no matches for the value #{parent_value} were found"
        raise RowFailed
      end
    rescue MultipleIssuesForUniqueValue
      @failed_count += 1
      @failed_issues[@failed_count] = row
      @messages << "Warning: When setting the parent for issue #{@failed_count} below," \
          " multiple matches for the value #{parent_value} were found"
      raise RowFailed
    end
  end

  def init_globals
    @handle_count = 0
    @update_count = 0
    @skip_count = 0
    @failed_count = 0
    @failed_issues = Hash.new
    @messages = Array.new
    @affect_projects_issues = Hash.new
    # This is a cache of previously inserted issues indexed by the value
    # the user provided in the unique column
    @issue_by_unique_attr = Hash.new
    # Cache of user id by login
    @user_by_login = Hash.new
    # Cache of Version by name
    @version_id_by_name = Hash.new
    # Cache of CustomFieldEnumeration by name
    @enumeration_id_by_name = Hash.new
  end

  def handle_watchers(issue, row, watchers)
    watcher_failed_count = 0
    if watchers
      addable_watcher_users = issue.addable_watcher_users
      watchers.split(',').each do |watcher|
        begin
          watcher_user = user_for_login!(watcher)
          if issue.watcher_users.include?(watcher_user)
            next
          end
          if addable_watcher_users.include?(watcher_user)
            issue.add_watcher(watcher_user)
          end
        rescue ActiveRecord::RecordNotFound
          if watcher_failed_count == 0
            @failed_count += 1
            @failed_issues[@failed_count] = row
          end
          watcher_failed_count += 1
          @messages << "Warning: When trying to add watchers on issue" \
                " #{@failed_count} below, User #{watcher} was not found"
        end
      end
    end
    raise RowFailed if watcher_failed_count > 0
  end

  def handle_custom_fields(add_versions, issue, project, row)
    custom_failed_count = 0
    issue.custom_field_values = issue.available_custom_fields.inject({}) do |h, cf|
      value = row[@attrs_map[cf.name]]
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
                      value.to_date.to_s(:db)
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
        rescue
          if custom_failed_count == 0
            custom_failed_count += 1
            @failed_count += 1
            @failed_issues[@failed_count] = row
          end
          @messages << "Warning: When trying to set custom field #{cf.name}" \
                         " on issue #{@failed_count} below, value #{value} was invalid"
        end
      end
      h
    end
    raise RowFailed if custom_failed_count > 0
  end

  private

  def fetch(key, row)
    row[@attrs_map[key]]
  end

  def log_failure(row, msg)
    @failed_count += 1
    @failed_issues[@failed_count] = row
    @messages << msg
  end

  def find_project
    @project = Project.find(params[:project_id])
  end

  def flash_message(type, text)
    flash[type] ||= ""
    flash[type] += "#{text}<br/>"
  end

  def validate_csv_data(csv_data)
    if csv_data.lines.to_a.size <= 1
      flash[:error] = 'No data line in your CSV, check the encoding of the file'\
        '<br/><br/>Header :<br/>'.html_safe + csv_data

      redirect_to project_importer_path(:project_id => @project)

      return
    end
  end

  def sample_data(iip)
    # display sample
    sample_count = 5
    @samples = []

    begin
      CSV.new(iip.csv_data, {:headers=>true,
                             :encoding=>iip.encoding,
                             :quote_char=>iip.quote_char,
                             :col_sep=>iip.col_sep}).each_with_index do |row, i|
                               @samples[i] = row
                               break if i >= sample_count
                             end # do

    rescue Exception => e
      csv_data_lines = iip.csv_data.lines.to_a

      error_message = e.message +
        '<br/><br/>Header :<br/>'.html_safe +
        csv_data_lines[0]

      # if there was an exception, probably happened on line after the last sampled.
      if csv_data_lines.size > 0
        error_message += '<br/><br/>Error on header or line :<br/>'.html_safe +
          csv_data_lines[@samples.size + 1]
      end

      flash[:error] = error_message

      redirect_to project_importer_path(:project_id => @project)

      return
    end
  end

  def set_csv_headers(iip)
    if @samples.size > 0
      @headers = @samples[0].headers
    end

    missing_header_columns = ''
    @headers.each_with_index{|h, i|
      if h.nil?
        missing_header_columns += " #{i+1}"
      end
    }

    if missing_header_columns.present?
      flash[:error] = "Column header missing : #{missing_header_columns}" \
      " / #{@headers.size} #{'<br/><br/>Header :<br/>'.html_safe}" \
      " #{iip.csv_data.lines.to_a[0]}"

      redirect_to project_importer_path(:project_id => @project)

      return
    end

  end

  # Returns the issue object associated with the given value of the given attribute.
  # Raises NoIssueForUniqueValue if not found or MultipleIssuesForUniqueValue
  def issue_for_unique_attr(unique_attr, attr_value, row_data)
    if @issue_by_unique_attr.has_key?(attr_value)
      return @issue_by_unique_attr[attr_value]
    end

    if unique_attr == "id"
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

      query = query_class.new(:name => "_importer", :project => @project)
      query.add_filter("status_id", "*", [1])
      query.add_filter(unique_attr, "=", [attr_value])

      issues = Issue.joins([:project])
                    .includes([ :assigned_to, :status, :tracker, :project, :priority,
                      :category, :fixed_version ])
                    .limit(2)
                    .where(query.statement)
    end

    if issues.size > 1
      @failed_count += 1
      @failed_issues[@failed_count] = row_data
      @messages << "Warning: Unique field #{unique_attr} with value " \
        "'#{attr_value}' in issue #{@failed_count} has duplicate record"
      raise MultipleIssuesForUniqueValue, "Unique field #{unique_attr} with" \
        " value '#{attr_value}' has duplicate record"
    elsif issues.size == 0 || issues[0].nil?
      raise NoIssueForUniqueValue, "No issue with #{unique_attr} of '#{attr_value}' found"
    else
      issues.first
    end
  end

  # Returns the id for the given user or raises RecordNotFound
  # Implements a cache of users based on login name
  def user_for_login!(login)
    begin
      if !@user_by_login.has_key?(login)
        @user_by_login[login] = User.find_by_login!(login)
      end
    rescue ActiveRecord::RecordNotFound
      if params[:use_anonymous]
        @user_by_login[login] = User.anonymous()
      else
        @unfound_class = "User"
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
    if !@version_id_by_name.has_key?(name)
      version = project.shared_versions.find_by_name(name)
      if !version
        if name && (name.length > 0) && add_versions
          version = project.versions.build(:name=>name)
          version.save
        else
          @unfound_class = "Version"
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
        @unfound_class = "CustomFieldEnumeration"
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
    return_value_by raw_value, "1", "0"
  end

  def return_value_by(raw_value, value_yes, value_no)
    case raw_value
    when I18n.t("general_text_yes")
      value_yes
    when I18n.t("general_text_no")
      value_no
    else
      nil
    end
  end

  class RowFailed < Exception
  end

end
