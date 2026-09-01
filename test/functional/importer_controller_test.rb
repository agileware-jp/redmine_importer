# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ImporterControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper

  fixtures :users

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
    @issue = create_issue!(@project, @user, { id: 70_385, tracker: @tracker })
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

  test 'should reject csv exceeding row limit' do
    # Set max row limit to 2
    Setting.stubs(:plugin_redmine_importer).returns({ 'max_csv_rows' => '2' })

    # Create CSV with more than 2 data rows
    csv_data = "id,subject,tracker\n"
    csv_data += "1,Issue 1,Bug\n"
    csv_data += "2,Issue 2,Bug\n"
    csv_data += "3,Issue 3,Bug\n" # This makes it 3 data rows

    file = Tempfile.new(['test', '.csv'])
    file.write(csv_data)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'UTF-8'
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].include?('exceeds the maximum allowed rows')
    assert flash[:error].include?('Maximum: 2')
    assert flash[:error].include?('Actual: 3')
  ensure
    file.close
    file.unlink
  end

  test 'should accept csv within row limit' do
    # Set max row limit to 5
    Setting.stubs(:plugin_redmine_importer).returns({ 'max_csv_rows' => '5' })

    # Create CSV with 2 data rows
    csv_data = "id,subject,tracker\n"
    csv_data += "1,Issue 1,Bug\n"
    csv_data += "2,Issue 2,Bug\n"

    file = Tempfile.new(['test', '.csv'])
    file.write(csv_data)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'UTF-8'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
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
    assert(%w[Tokyo Osaka].all? { |area| area.in?(keyval_vals_for(Issue.find_by!(subject: 'タピオカ'))) })
    assert Issue.find_by(subject: 'サーターアンダギー').nil?
  end

  test 'should handle issue relation' do
    other_issue = create_issue!(@project, @user, { subject: 'other_issue' })
    @iip.update!(csv_data: "#,Subject,Duplicated issue ID\n#{@issue.id},set other issue relation,#{other_issue.id}\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1').tap { |params|
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

  test 'should handle parent issue defined after child in CSV using # column as unique key' do
    # CSV: Child issue (#=1, parent=2) comes before Parent issue (#=2)
    # Uses sequential numbers in # column as internal CSV reference (not DB ID)
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n1,Child Issue,Defect,New,Critical,2\n2,Parent Issue,Defect,New,Critical,\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority',
        'Parent' => 'standard_field-parent_issue'
      }
    }
    assert_response :success
    assert !response.body.include?('Warning'), "Unexpected warning in response"

    child = Issue.find_by!(subject: 'Child Issue')
    parent = Issue.find_by!(subject: 'Parent Issue')
    assert_equal parent.id, child.parent_id
  end

  test 'should handle issue relation defined later in CSV with empty values skipped' do
    # CSV: #=2 comes first and references #=1 which comes later (descending order)
    # This matches Redmine export format where newer issues appear first
    # #=1 has empty relation value which should be skipped without warning
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Related issue\n2,Issue Two,Defect,New,Critical,1\n1,Issue One,Defect,New,Critical,\"\"\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority',
        'Related issue' => "issue_relation-#{IssueRelation::TYPE_RELATES}"
      }
    }
    assert_response :success
    assert !response.body.include?('Warning'), "Unexpected warning: #{response.body}"

    issue_one = Issue.find_by!(subject: 'Issue One')
    issue_two = Issue.find_by!(subject: 'Issue Two')
    # issue_two should have a relation to issue_one (deferred resolution worked)
    assert_equal 1, issue_two.relations.count, "Expected issue_two to have 1 relation"
    relation = issue_two.relations.first
    assert_equal issue_one.id, relation.other_issue(issue_two).id
  end

  test 'should warn when deferred reference target is not found in CSV' do
    # CSV: Child issue references parent "999" which doesn't exist in CSV
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n1,Orphan Issue,Defect,New,Critical,999\n")
    post :result, params: {
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.id,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Priority' => 'standard_field-priority',
        'Parent' => 'standard_field-parent_issue'
      }
    }
    assert_response :success
    assert response.body.include?('Warning')
    assert response.body.include?('999')
    assert response.body.include?('never resolved')

    orphan = Issue.find_by!(subject: 'Orphan Issue')
    assert_nil orphan.parent_id
  end

  test 'should error when assigned_to is missing' do
    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,JohnDoe\n")
    @issue.reload.update!(assigned_to: @user)
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
    @issue.reload.update!(assigned_to: @user)
    post :result, params: build_params(update_issue: 'true', use_anonymous: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_nil @issue.assigned_to
  end

  test 'should match assigned_to by user display name' do
    user = User.find_by_login('jsmith')
    Member.create!(user: user, project: @project, roles: [@role])

    @iip.update!(csv_data: "#,Subject,assigned_to\n#{@issue.id},barfooz,#{user.name}\n")
    post :result, params: build_params(update_issue: 'true').tap { |params|
                            params[:fields_map]['assigned_to'] = 'standard_field-assigned_to'
                          }
    assert_response :success
    assert_not response.body.include?('Warning')
    @issue.reload
    assert_equal 'barfooz', @issue.subject
    assert_equal user, @issue.assigned_to
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

  test "should NOT change an open issue's parent to an closed issue" do
    closed_status = IssueStatus.find_or_create_by!(name: 'Closed', is_closed: true)
    parent = create_issue!(@project, @user, status: closed_status)
    @iip.update!(csv_data: "#,Parent\n#{@issue.id},#{parent.id}\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1')
    assert_response :success
    assert response.body.include?('Error')
    assert_nil @issue.reload.parent
  end

  test 'should NOT close an issue having open children' do
    @child = create_issue!(@project, @user, parent_id: @issue.id)
    assert @issue.children.include?(@child)
    assert !@issue.status.is_closed?
    assert !@child.status.is_closed?
    IssueStatus.find_or_create_by!(name: 'Closed', is_closed: true)
    @iip.update!(csv_data: "#,Status\n#{@issue.id},Closed\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1')
    assert_response :success
    assert response.body.include?('Error')
    assert !@issue.reload.status.is_closed?
  end

  test 'should NOT reopen an issue having closed parent' do
    closed_status = IssueStatus.find_or_create_by!(name: 'Closed', is_closed: true)
    new_issue = create_issue!(@project, @user, status: closed_status)
    @issue.reload.update!(status: closed_status, parent_id: new_issue.id)
    @iip.update!(csv_data: "#,Status\n#{@issue.id},New\n")
    post :result, params: build_params(update_issue: 'true', use_issue_id: '1')
    assert_response :success
    assert response.body.include?('Error')
    assert @issue.reload.status.is_closed?
  end

  test 'should handle date custom field on create' do
    start_date_field = create_date_custom_field!('StartDate', @project)
    due_date_field = create_date_custom_field!('DueDate', @project)
    @tracker.custom_fields << start_date_field
    @tracker.custom_fields << due_date_field
    Issue.delete_all
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,StartDate,DueDate\n1,Task with dates,Defect,New,Critical,2023-05-15,2023-06-30\n")
    post :result, params: build_params.tap { |params|
      params[:fields_map]['StartDate'] = 'custom_field-StartDate'
      params[:fields_map]['DueDate'] = 'custom_field-DueDate'
    }
    assert_response :success
    assert !response.body.include?('Warning')
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'Task with dates', issue.subject
    assert_equal '2023-05-15', issue.custom_value_for(start_date_field).value
    assert_equal '2023-06-30', issue.custom_value_for(due_date_field).value
  end

  test 'should handle date custom field on update' do
    start_date_field = create_date_custom_field!('StartDate', @project)
    @tracker.custom_fields << start_date_field
    @issue.reload
    @issue.custom_field_values.detect { |cfv| cfv.custom_field == start_date_field }.value = '2023-01-01'
    @issue.save!
    @iip.update!(csv_data: "#,Subject,StartDate\n#{@issue.id},Updated task,2023-12-25\n")
    post :result, params: build_params(update_issue: 'true').tap { |params|
      params[:fields_map]['StartDate'] = 'custom_field-StartDate'
    }
    assert_response :success
    assert !response.body.include?('Warning')
    @issue.reload
    assert_equal 'Updated task', @issue.subject
    assert_equal '2023-12-25', @issue.custom_value_for(start_date_field).value
  end

  test 'should handle blank date custom field' do
    start_date_field = create_date_custom_field!('StartDate', @project)
    @tracker.custom_fields << start_date_field
    Issue.delete_all
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,StartDate\n1,Task with blank date,Defect,New,Critical,\n")
    post :result, params: build_params.tap { |params|
      params[:fields_map]['StartDate'] = 'custom_field-StartDate'
    }
    assert_response :success
    assert !response.body.include?('Warning')
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'Task with blank date', issue.subject
    # Blank date values are stored as empty strings, not nil
    assert_equal '', issue.custom_value_for(start_date_field).value
  end

  test 'should handle invalid date custom field value' do
    invalid_date_field = create_date_custom_field!('InvalidDate', @project)
    @tracker.custom_fields << invalid_date_field
    Issue.delete_all
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,InvalidDate\n1,Task with invalid date,Defect,New,Critical,not-a-date\n")
    post :result, params: build_params.tap { |params|
      params[:fields_map]['InvalidDate'] = 'custom_field-InvalidDate'
    }
    assert_response :success
    assert response.body.include?('Warning')
    assert_equal 0, Issue.count
  end

  test 'should handle start_date with different format than setting' do
    Issue.delete_all
    with_settings :date_format => '%Y-%m-%d' do
      @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Start date\n1,Task with different date format,Defect,New,Critical,15/05/2023\n")
      post :result, params: build_params.tap { |params|
        params[:fields_map]['Start date'] = 'standard_field-start_date'
      }
      assert_response :success
      assert !response.body.include?('Warning')
      assert_equal 1, Issue.count
      issue = Issue.first
      assert_equal 'Task with different date format', issue.subject
      assert_equal Date.new(2023, 5, 15), issue.start_date
    end
  end

  test 'should redirect with error when encoding does not match file' do
    # CSV including Shift-JIS bytes (not UTF-8)
    sjis_csv = "id,件名\n1,テスト件名\n".encode('Shift_JIS')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(sjis_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'  # Incorrectly set to UTF-8
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].present?, 'encoding mismatch error should be shown'
    assert flash[:error].encoding == Encoding::UTF_8, 'flash must be UTF-8'
  ensure
    file.close
    file.unlink
  end

  test 'should redirect with error when EUC-JP file is uploaded with UTF-8 encoding' do
    # Regression test: force_encoding('UTF-8').encode('UTF-8') was a no-op in Ruby
    # (same-encoding optimization), so EUC-JP bytes were never validated.
    euc_csv = "id,件名\n1,テスト件名\n".encode('EUC-JP')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(euc_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'  # Incorrectly set to UTF-8
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].present?, 'encoding mismatch error should be shown'
    assert_equal Encoding::UTF_8, flash[:error].encoding
  ensure
    file.close
    file.unlink
  end

  test 'should proceed normally when encoding matches file' do
    utf8_csv = "#,Subject\n1,テスト件名\n"

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(utf8_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
  end

  test 'should proceed normally when EUC-JP encoding matches file' do
    euc_csv = "#,Subject\n1,テスト件名\n".encode('EUC-JP')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(euc_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'EUC'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
  end

  test 'should proceed normally when Shift_JIS encoding matches file' do
    sjis_csv = "#,Subject\n1,テスト件名\n".encode('Shift_JIS')

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(sjis_csv)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'S'
    }

    assert_response :success
    assert_nil flash[:error]
  ensure
    file.close
    file.unlink
  end

  test 'should redirect with error when CSV has missing header columns with non-ASCII content' do
    # The second column is empty, causing a nil header, and also includes non-ASCII characters.
    csv_content = "id,,件名\n1,,テスト\n"

    file = Tempfile.new(['test', '.csv'])
    file.binmode
    file.write(csv_content)
    file.rewind

    post :match, params: {
      project_id: @project.identifier,
      file: Rack::Test::UploadedFile.new(file.path, 'text/csv'),
      wrapper: '"',
      splitter: ',',
      encoding: 'U'
    }

    assert_redirected_to project_importer_path(project_id: @project.identifier)
    assert flash[:error].present?
    assert_equal Encoding::UTF_8, flash[:error].encoding
  ensure
    file.close
    file.unlink
  end

  test 'should use id-based search when use_issue_id is true' do
    # Create parent issue (id will be auto-generated)
    parent = create_issue!(@project, @user, subject: 'Parent Issue')

    # With use_issue_id=true, parent should be found by id
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n100,Child A,Defect,New,Critical,#{parent.id}\n")
    post :result, params: build_params(use_issue_id: '1')
    assert_response :success
    assert !response.body.include?('Warning')

    child_a = Issue.find(100)
    assert_equal parent.id, child_a.parent_id
  end

  test 'should not use id-based search when use_issue_id is false' do
    # Create parent issue (id will be auto-generated)
    parent = create_issue!(@project, @user, subject: 'Parent Issue')

    # With use_issue_id=false and unique_field='#' -> 'standard_field-id'
    # Before fix: Would incorrectly use id-based search
    # After fix: Uses query filter which should fail or behave differently
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Parent\n101,Child B,Defect,New,Critical,#{parent.id}\n")
    post :result, params: build_params # use_issue_id defaults to false
    assert_response :success

    # After the fix, since 'standard_field-id' is not a valid IssueQuery filter,
    # the parent lookup should fail and produce a warning or error
    child_b = Issue.find_by(subject: 'Child B')

    # The expected behavior after fix: either warning is shown, or parent is not set
    # (depending on how IssueQuery handles invalid filters)
    if child_b
      # If issue was created, parent should not be set correctly
      # because the query filter 'standard_field-id' is invalid
      assert_nil child_b.parent_id,
        'Parent should not be set when use_issue_id=false with standard_field-id as unique_attr'
    else
      # Issue creation failed, check for warning
      assert response.body.include?('Warning'),
        'Should show warning when using standard_field-id without use_issue_id=true'
    end
  end

  test 'should update only the matching issue when unique field is Subject and multiple open issues exist' do
    other1 = create_issue!(@project, @user, { subject: 'unrelated one' })
    other2 = create_issue!(@project, @user, { subject: 'unrelated two' })
    @iip.update!(csv_data: "Subject,Start date\nfoobar,2030-01-15\n")
    post :result, params: build_params(update_issue: 'true', unique_field: 'Subject').tap { |params|
                            params[:fields_map]['Start date'] = 'standard_field-start_date'
                          }
    assert_response :success
    assert_equal Date.new(2030, 1, 15), @issue.reload.start_date
    assert_not_equal Date.new(2030, 1, 15), other1.reload.start_date
    assert_not_equal Date.new(2030, 1, 15), other2.reload.start_date
  end

  test 'should update only the issue with matching id when unique field is # and use_issue_id is off' do
    other = create_issue!(@project, @user, { subject: 'unrelated' })
    @iip.update!(csv_data: "#,Subject\n#{@issue.id},renamed by import\n")
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    assert_equal 'renamed by import', @issue.reload.subject
    assert_equal 'unrelated', other.reload.subject
  end

  test 'should not update an unrelated issue when the unique value matches nothing' do
    @iip.update!(csv_data: "Subject,Start date\nno such subject,2030-01-15\n")
    post :result, params: build_params(update_issue: 'true', unique_field: 'Subject').tap { |params|
                            params[:fields_map]['Start date'] = 'standard_field-start_date'
                          }
    assert_response :success
    assert_equal 'foobar', @issue.reload.subject
    assert_not_equal Date.new(2030, 1, 15), @issue.start_date
    assert response.body.include?('no match for the value')
  end

  test 'should resolve parent by subject when multiple open issues exist' do
    create_issue!(@project, @user, { subject: 'unrelated one' })
    @iip.update!(csv_data: "Subject,Tracker,Status,Priority,Parent\nchild by subject,Defect,New,Critical,foobar\n")
    post :result, params: build_params(unique_field: 'Subject')
    assert_response :success
    child = Issue.find_by!(subject: 'child by subject')
    assert_equal @issue.id, child.parent_id
  end

  test 'should update the issue found by custom field unique value' do
    ref_field = IssueCustomField.create!(name: 'RefNo', field_format: 'string',
                                         is_filter: true, projects: [@project],
                                         trackers: [@tracker])
    @issue.reload
    @issue.custom_field_values = { ref_field.id => 'REF-1' }
    @issue.save!
    other = create_issue!(@project, @user, { subject: 'other with ref', tracker: @tracker }).reload
    other.custom_field_values = { ref_field.id => 'REF-2' }
    other.save!
    @iip.update!(csv_data: "RefNo,Subject,Tracker\nREF-2,renamed via cf,Defect\n")
    post :result, params: build_params(update_issue: 'true', unique_field: 'RefNo').tap { |params|
                            params[:fields_map]['RefNo'] = 'custom_field-RefNo'
                          }
    assert_response :success
    assert_equal 'renamed via cf', other.reload.subject
    assert_equal 'foobar', @issue.reload.subject
  end

  test 'should fail the row with a clear error when unique field cannot be used for lookup' do
    create_issue!(@project, @user, { subject: 'unrelated one' })
    @iip.update!(csv_data: "Priority,Subject\nCritical,should not be applied\n")
    post :result, params: build_params(update_issue: 'true', unique_field: 'Priority')
    assert_response :success
    assert_equal 'foobar', @issue.reload.subject
    assert_nil Issue.find_by(subject: 'should not be applied')
    assert response.body.include?('cannot be used to find existing issues')
  end

  protected

  def build_params(opts = {})
    @iip.reload
    opts.reverse_merge(
      import_timestamp: @iip.created.strftime('%Y-%m-%d %H:%M:%S'),
      unique_field: '#',
      project_id: @project.identifier,
      fields_map: {
        '#' => 'standard_field-id',
        'Subject' => 'standard_field-subject',
        'Tags' => 'custom_field-Tags',
        'Affected versions' => 'custom_field-Affected versions',
        'Priority' => 'standard_field-priority',
        'Tracker' => 'standard_field-tracker',
        'Status' => 'standard_field-status',
        'Watchers' => 'standard_field-watchers',
        'Parent' => 'standard_field-parent_issue',
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
    user.pref.auto_watch_on = nil if Redmine::VERSION.to_s.to_f >= 5.1
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
    issue.parent_id = options[:parent_id]
    issue.project = project
    issue.subject = options[:subject] || 'foobar'
    issue.priority = IssuePriority.find_or_create_by!(name: 'Critical')
    issue.tracker = options[:tracker] || project.trackers.first
    issue.author = author
    issue.status = options[:status] || IssueStatus.find_or_create_by!(name: 'New')
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

  def create_date_custom_field!(name, project)
    field = IssueCustomField.new name: name, multiple: false
    field.field_format = 'date'
    field.projects << project
    field.save!
    field
  end

  def get_csv(filename)
    File.read(File.expand_path("../../samples/#{filename}.csv", __FILE__))
  end
end
