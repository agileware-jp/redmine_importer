# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ImporterControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper

  def setup
    ActionController::Base.allow_forgery_protection = false
    @project = Project.create! name: 'foo', identifier: 'importer_controller_test'
    @tracker = Tracker.new(name: 'Defect')
    @tracker.default_status = IssueStatus.find_or_create_by!(name: 'New')
    @tracker.save!
    @project.trackers << @tracker
    @project.save!
    @role = Role.create! name: 'ADMIN', permissions: %i[import view_issues]
    @user = create_user!(@role, @project)
    @iip = create_iip_for_multivalues!(@user, @project)
    @issue = create_issue!(@project, @user, { id: 70_385 })
    create_custom_fields!(@issue)
    create_versions!(@project)
    User.stubs(:current).returns(@user)
  end

  test 'should handle multiple values for versions' do
    assert issue_has_none_of_these_multival_versions?(@issue,
                                                      %w[Admin 2013-09-25])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_these_multival_versions?(@issue, %w[Admin 2013-09-25])
  end

  test 'should handle multiple values' do
    assert issue_has_none_of_these_multifield_vals?(@issue, %w[tag1 tag2])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_these_multifield_vals?(@issue, %w[tag1 tag2])
  end

  test 'should handle single-value fields' do
    assert_equal 'foobar', @issue.subject
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal @user.today, @issue.start_date
  end

  test 'should create issue if none exists' do
    Mailer.expects(:deliver_issue_add).never
    Issue.delete_all
    assert_equal 0, Issue.count
    post :result, params: build_params
    assert_response :success
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'barfooz', issue.subject
  end

  test 'should send email when Send email notifications checkbox is checked and issue updated' do
    assert_equal 'foobar', @issue.subject
    Mailer.expects(:deliver_issue_edit)

    post :result, params: build_params(update_issue: 'true', send_emails: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  test 'should send email when Send email notifications checkbox is checked and issue added' do
    assert_equal 'foobar', @issue.subject
    Mailer.expects(:deliver_issue_add)

    assert_equal 0, Issue.where(subject: 'barfooz').count
    post :result, params: build_params(send_emails: 'true')
    assert_response :success
    assert_equal 1, Issue.where(subject: 'barfooz').count
  end

  test 'should NOT send email when Send email notifications checkbox is unchecked' do
    assert_equal 'foobar', @issue.subject
    Mailer.expects(:deliver_issue_edit).never

    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  test 'should add watchers' do
    assert issue_has_none_of_these_watchers?(@issue, [@user])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_of_these_watchers?(@issue, [@user])
  end

  test 'should handle key value list value' do
    Mailer.expects(:deliver_issue_add).never
    IssueCustomField.where(name: 'Area').each { |icf| icf.update(multiple: false) }
    @iip.destroy
    @iip = create_iip!('KeyValueList', @user, @project)
    post :result, params: build_params
    assert_response :success
    assert keyval_vals_for(Issue.find_by!(subject: 'パンケーキ')) == ['Tokyo']
    assert keyval_vals_for(Issue.find_by!(subject: 'たこ焼き')) == ['Osaka']
    assert Issue.find_by(subject: 'サーターアンダギー').nil?
  end

  test 'should handle multiple key value list values' do
    Mailer.expects(:deliver_issue_add).never
    @iip.destroy
    @iip = create_iip!('KeyValueListMultiple', @user, @project)
    post :result, params: build_params
    assert_response :success
    assert keyval_vals_for(Issue.find_by!(subject: 'パンケーキ')) == ['Tokyo']
    assert keyval_vals_for(Issue.find_by!(subject: 'たこ焼き')) == ['Osaka']
    issue = Issue.find_by!(subject: 'タピオカ')
    assert %w[Tokyo Osaka].all? { |area| area.in?(keyval_vals_for(Issue.find_by!(subject: 'タピオカ'))) }
    assert Issue.find_by(subject: 'サーターアンダギー').nil?
  end

  test 'should handle issue relation' do
    other_issue = create_issue!(@project, @user, { subject: 'other_issue' })
    @iip.update!(csv_data: "#,Subject,Duplicated issue ID\n#{@issue.id},set other issue relation,#{other_issue.id}\n")
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['Duplicated issue ID'] = "issue_relation-#{IssueRelation::TYPE_DUPLICATED}"
                          }
    assert_response :success
    @issue.reload
    assert_equal 'set other issue relation', @issue.subject
    issue_relation = @issue.relations_to.first!
    assert_equal other_issue, issue_relation.issue_from
    assert_equal IssueRelation::TYPE_DUPLICATES, issue_relation.relation_type
    assert_equal 1, @issue.relations_to.count
  end

  test 'should error when assigned_to is missing' do
    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,JohnDoe\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert response.body.include?('Warning')
    @issue.reload
    assert_equal 'foobar', @issue.subject
    assert_equal @user, @issue.assigned_to
  end

  test 'should unset assigned_to when assigned_to user is not assignable' do
    User.create!(login: 'john', firstname: 'John', lastname: 'Doe', mail: 'john.doe@example.com')
    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,john\n")
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_nil @issue.assigned_to
  end

  test 'should error when user type CF value is missing' do
    assigned_by_field = create_multivalue_field!('assigned_by', 'user', @issue.project)
    @tracker.custom_fields << assigned_by_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == assigned_by_field }.value = @user
    @iip.update!(csv_data: "#,Subject,assigned_by\n#{@issue.id},barfooz,JeanDoe\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_by'] = 'standard_field-assigned_by'
                          }
    assert_response :success
    assert response.body.include?('Warning')
    @issue.reload
    assert_equal 'foobar', @issue.subject
    assert_equal @user.name, @issue.custom_value_for(assigned_by_field).value
  end

  test 'should not error when assigned_to is missing but use_anonymous is true' do
    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,JohnDoe\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true', use_anonymous: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_nil @issue.assigned_to
  end

  test 'should not error when user type CF value is missing but use_anonymous is true' do
    assigned_by_field = create_multivalue_field!('assigned_by', 'user', @issue.project)
    @tracker.custom_fields << assigned_by_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == assigned_by_field }.value = @user
    @iip.update!(csv_data: "#,Subject,assigned_by\n#{@issue.id},barfooz,JeanDoe\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true', use_anonymous: 'true').tap { |params|
                            params[:fields_map]['assigned_by'] = 'custom_field-assigned_by'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal '', @issue.custom_value_for(assigned_by_field).value
  end

  test 'should not error when user type CF value is not listed in possible values' do
    User.create!(login: 'john', firstname: 'John', lastname: 'Doe', mail: 'john.doe@example.com')
    assigned_by_field = create_multivalue_field!('assigned_by', 'user', @issue.project)
    @tracker.custom_fields << assigned_by_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == assigned_by_field }.value = @user
    @iip.update!(csv_data: "#,Subject,assigned_by\n#{@issue.id},barfooz,john\n")
    @issue.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true', use_anonymous: 'true').tap { |params|
                            params[:fields_map]['assigned_by'] = 'custom_field-assigned_by'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal '', @issue.custom_value_for(assigned_by_field).value
  end

  test 'should reset pk sequence' do
    return unless ActiveRecord::Base.connection.respond_to?(:set_pk_sequence!)
    return unless ActiveRecord::Base.connection.respond_to?(:reset_pk_sequence!)

    ActiveRecord::Base.connection.set_pk_sequence!('issues', 4422)

    @iip.update!(csv_data: "#,Subject,Tracker,Priority\n4423,test,Defect,Critical\n")
    post :result, params: build_params(use_issue_id: '1')
    assert_response :success
    assert !response.body.include?('Warning')

    issue = Issue.new
    issue.project = @project
    issue.subject = 'foobar'
    issue.priority = IssuePriority.find_by!(name: 'Critical')
    issue.tracker = @project.trackers.first
    issue.author = @user
    issue.status = IssueStatus.find_by!(name: 'New')
    issue.save!
  end

  protected

  def build_params(opts = {})
    @iip.reload
    opts.reverse_merge(
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tags' => 'custom_field-Tags',
        'Affected versions' => 'custom_field-Affected versions',
        'Priority' => 'standard_field-priority',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Watchers' => 'standard_field-watchers',
        'Area' => 'custom_field-Area'
      }
    )
  end

  def issue_has_all_these_multival_versions?(issue, version_names)
    find_version_ids(version_names).all? do |version_to_find|
      versions_for(issue).include?(version_to_find)
    end
  end

  def issue_has_none_of_these_multival_versions?(issue, version_names)
    find_version_ids(version_names).none? do |version_to_find|
      versions_for(issue).include?(version_to_find)
    end
  end

  def issue_has_none_of_these_watchers?(issue, watchers)
    watchers.none? do |watcher|
      issue.watcher_users.include?(watcher)
    end
  end

  def issue_has_all_of_these_watchers?(issue, watchers)
    watchers.all? do |watcher|
      issue.watcher_users.include?(watcher)
    end
  end

  def find_version_ids(version_names)
    version_names.map do |name|
      Version.find_by_name!(name).id.to_s
    end
  end

  def versions_for(issue)
    versions_field = CustomField.find_by_name! 'Affected versions'
    value_objs = issue.custom_values.where(custom_field_id: versions_field.id)
    values = value_objs.map(&:value)
  end

  def issue_has_all_these_multifield_vals?(issue, vals_to_find)
    vals_to_find.all? do |val_to_find|
      multifield_vals_for(issue).include?(val_to_find)
    end
  end

  def issue_has_none_of_these_multifield_vals?(issue, vals_to_find)
    vals_to_find.none? do |val_to_find|
      multifield_vals_for(issue).include?(val_to_find)
    end
  end

  def multifield_vals_for(issue)
    multival_field = CustomField.find_by_name! 'Tags'
    value_objs = issue.custom_values.where(custom_field_id: multival_field.id)
    values = value_objs.map(&:value)
  end

  def keyval_vals_for(issue)
    keyval_field = CustomField.find_by_name! 'Area'
    value_objs = issue.custom_values.where(custom_field_id: keyval_field.id)
    value_objs.map { |value_obj| keyval_field.enumerations.find(value_obj.value).name }
  end

  def create_user!(role, project)
    user = User.new admin: true,
                    login: 'bob',
                    firstname: 'Bob',
                    lastname: 'Loblaw',
                    mail: 'bob.loblaw@example.com'
    user.login = 'bob'
    sponsor = User.new admin: true,
                       firstname: 'A',
                       lastname: 'H',
                       mail: 'a@example.com'
    sponsor.login = 'alice'

    membership = user.memberships.build(project: project)
    membership.roles << role
    membership.principal = user

    membership = sponsor.memberships.build(project: project)
    membership.roles << role
    membership.principal = sponsor
    sponsor.save!
    user.save!
    user
  end

  def create_iip_for_multivalues!(user, project)
    create_iip!('CustomFieldMultiValues', user, project)
  end

  def create_iip!(filename, user, _project)
    iip = ImportInProgress.new
    iip.user = user
    iip.csv_data = get_csv(filename)
    # iip.created = DateTime.new(2001,2,3,4,5,6,'+7')
    iip.created = DateTime.now
    iip.encoding = 'UTF-8'
    iip.col_sep = ','
    iip.quote_char = '"'
    iip.save!
    iip
  end

  def create_issue!(project, author, options = {})
    issue = Issue.new
    issue.id = options[:id]
    issue.project = project
    issue.subject = options[:subject] || 'foobar'
    issue.priority = IssuePriority.find_or_create_by!(name: 'Critical')
    issue.tracker = project.trackers.first
    issue.author = author
    issue.status = IssueStatus.find_or_create_by!(name: 'New')
    issue.start_date = author.today
    issue.save!
    issue
  end

  def create_custom_fields!(issue)
    versions_field = create_multivalue_field!('Affected versions',
                                              'version',
                                              issue.project)
    multival_field = create_multivalue_field!('Tags',
                                              'list',
                                              issue.project,
                                              %w[tag1 tag2])
    keyval_field = create_enumeration_field!('Area',
                                             issue.project,
                                             %w[Tokyo Osaka])
    issue.tracker.custom_fields << versions_field
    issue.tracker.custom_fields << multival_field
    issue.tracker.custom_fields << keyval_field
    issue.tracker.save!
  end

  def create_multivalue_field!(name, format, project, possible_vals = [])
    field = IssueCustomField.new name: name, multiple: true
    field.field_format = format
    field.projects << project
    field.possible_values = possible_vals if possible_vals
    field.save!
    field
  end

  def create_enumeration_field!(name, project, enumerations)
    field = IssueCustomField.new name: name, multiple: true, field_format: 'enumeration'
    field.projects << project
    field.save!
    enumerations.each.with_index(1) do |name, position|
      CustomFieldEnumeration.create!(name: name, custom_field_id: field.id, active: true, position: position)
    end
    field
  end

  def create_versions!(project)
    project.versions.create! name: 'Admin', status: 'open'
    project.versions.create! name: '2013-09-25', status: 'open'
  end

  def get_csv(filename)
    File.read(File.expand_path("../../samples/#{filename}.csv", __FILE__))
  end
end
