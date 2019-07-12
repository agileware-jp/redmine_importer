require File.expand_path('../../test_helper', __FILE__)

class ImporterControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper

  def setup
    @project = Project.create! :name => 'foo', :identifier => 'importer_controller_test'
    @tracker = Tracker.new(:name => 'Defect')
    @tracker.default_status = IssueStatus.find_or_create_by!(name: 'New')
    @tracker.save!
    @project.trackers << @tracker
    @project.save!
    @role = Role.create! :name => 'ADMIN', :permissions => [:import, :view_issues]
    @user = create_user!(@role, @project)
    @iip = create_iip_for_multivalues!(@user, @project)
    @issue = create_issue!(@project, @user)
    create_custom_fields!(@issue)
    create_versions!(@project)
    User.stubs(:current).returns(@user)
  end

  test 'should handle multiple values for versions' do
    assert issue_has_none_of_these_multival_versions?(@issue,
                                                      ['Admin', '2013-09-25'])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_these_multival_versions?(@issue, ['Admin', '2013-09-25'])
  end

  test 'should handle multiple values' do
    assert issue_has_none_of_these_multifield_vals?(@issue, ['tag1', 'tag2'])
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert issue_has_all_these_multifield_vals?(@issue, ['tag1', 'tag2'])
  end

  test 'should handle single-value fields' do
    assert_equal 'foobar', @issue.subject
    post :result, params: build_params(update_issue: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
  end

  test 'should create issue if none exists' do
    Issue.delete_all
    assert_equal 0, Issue.count
    post :result, params: build_params
    assert_response :success
    assert_equal 1, Issue.count
    issue = Issue.first
    assert_equal 'barfooz', issue.subject
  end

  test 'should send email when Send email notifications checkbox is checked' do
    assert_equal 'foobar', @issue.subject
    Mailer.expects(:deliver_issue_edit)

    post :result, params: build_params(update_issue: 'true', send_emails: 'true')
    assert_response :success
    @issue.reload
    assert_equal 'barfooz', @issue.subject
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

  test 'should handle key value list value (add enumeration)' do
    IssueCustomField.where(name: 'Area').each { |icf| icf.update(multiple: false) }
    @iip.destroy
    @iip = create_iip!('KeyValueList', @user, @project)
    assert CustomFieldEnumeration.find_by(name: 'Okinawa').nil?
    post :result, params: build_params(add_enumerations: true)
    assert_response :success
    assert keyval_vals_for(Issue.find_by!(subject: 'パンケーキ')) == ['Tokyo']
    assert keyval_vals_for(Issue.find_by!(subject: 'たこ焼き')) == ['Osaka']
    assert keyval_vals_for(Issue.find_by!(subject: 'サーターアンダギー')) == ['Okinawa']
    assert CustomFieldEnumeration.find_by(name: 'Okinawa')
  end

  test 'should handle key value list value (not add enumeration)' do
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
    @iip.destroy
    @iip = create_iip!('KeyValueListMultiple', @user, @project)
    post :result, params: build_params(add_enumerations: true)
    assert_response :success
    assert keyval_vals_for(Issue.find_by!(subject: 'パンケーキ')) == ['Tokyo']
    assert keyval_vals_for(Issue.find_by!(subject: 'たこ焼き')) == ['Osaka']
    issue = Issue.find_by!(subject: 'タピオカ')
    assert ['Tokyo', 'Osaka', 'Okinawa'].all? { |area| area.in?(keyval_vals_for(Issue.find_by!(subject: 'タピオカ'))) }
  end

  test 'should handle multiple key value list values (not add enumeration)' do
    @iip.destroy
    @iip = create_iip!('KeyValueListMultiple', @user, @project)
    post :result, params: build_params
    assert_response :success
    assert keyval_vals_for(Issue.find_by!(subject: 'パンケーキ')) == ['Tokyo']
    assert keyval_vals_for(Issue.find_by!(subject: 'たこ焼き')) == ['Osaka']
    assert Issue.find_by(subject: 'タピオカ').nil?
  end

  test 'set issue id if use_issue_id=true' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority\n4423,Hi,Defect,New,Critical\n")
    post :result, params: build_params(use_issue_id: 'true')
    assert Issue.where(id: 4423, subject: 'Hi').exists?
  end

  test 'not set issue id if use_issue_id=' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority\n4423,Hi,Defect,New,Critical\n")
    post :result, params: build_params(use_issue_id: nil)
    assert !Issue.where(id: 4423, subject: 'Hi').exists?
  end

  test 'set author by author column' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Author\n4423,Hi,Defect,New,Critical,alice\n")
    post :result, params: build_params.tap { |params| params[:fields_map]['Author'] = 'author' }
    assert Issue.where(subject: 'Hi', author: User.find_by!(login: 'alice')).exists?
  end

  test 'set author to current_user' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Author\n4423,Hi,Defect,New,Critical,alice\n")
    post :result, params: build_params
    assert Issue.where(subject: 'Hi', author: User.find_by!(login: 'bob')).exists?
  end

  test 'add category if add_categories=true' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Category\n4423,Hi,Defect,New,Critical,cat\n")
    post :result, params: build_params(add_categories: 'true').tap { |params| params[:fields_map]['Category'] = 'category' }
    assert IssueCategory.where(project: @project, name: 'cat').exists?
  end

  test 'not add category if add_categories=' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Category\n4423,Hi,Defect,New,Critical,cat\n")
    post :result, params: build_params.tap { |params| params[:fields_map]['Category'] = 'category' }
    assert !IssueCategory.where(project: @project, name: 'cat').exists?
  end

  test 'add version if add_versions=true' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Version\n4423,Hi,Defect,New,Critical,ver\n")
    post :result, params: build_params(add_versions: 'true').tap { |params| params[:fields_map]['Version'] = 'fixed_version' }
    assert Version.where(project: @project, name: 'ver').exists?
  end

  test 'not add version if add_versions=' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,Version\n4423,Hi,Defect,New,Critical,ver\n")
    post :result, params: build_params.tap { |params| params[:fields_map]['Version'] = 'fixed_version' }
    assert !Version.where(project: @project, name: 'ver').exists?
  end

  test 'assign issue to assigned_to column' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,AssignedTo\n4423,Hi,Defect,New,Critical,alice\n")
    post :result, params: build_params.tap { |params| params[:fields_map]['AssignedTo'] = 'assigned_to' }
    assert Issue.where(subject: 'Hi', assigned_to: User.find_by!(login: 'alice')).exists?
  end

  test 'not assign issue' do
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority,AssignedTo\n4423,Hi,Defect,New,Critical,\n")
    post :result, params: build_params.tap { |params| params[:fields_map]['AssignedTo'] = 'assigned_to' }
    assert !Issue.where(subject: 'Hi', assigned_to: User.find_by!(login: 'alice')).exists?
  end

  test 'set default project/tracker/author' do
    @iip.update!(csv_data: "Subject,Priority\ntest default,Critical\n")
    post :result, params: build_params(default_tracker: @tracker.id)
    assert Issue.where(subject: 'test default', tracker: @tracker, author: @user).exists?
  end

  test 'send email once when Send email notifications checkbox is not checked and issue added' do
    Mailer.expects(:deliver_issue_add)

    @iip.update!(csv_data: "Subject,Tracker,Priority\ntest default,Defect,Critical\n")
    post :result, params: build_params
  end

  test 'send email twice when Send email notifications checkbox is checked and issue added' do
    # It send notification email twice
    # - redmine_importer
    # - issue callback
    Mailer.expects(:deliver_issue_add).twice

    @iip.update!(csv_data: "Subject,Tracker,Priority\ntest default,Defect,Critical\n")
    post :result, params: build_params(send_emails: 'true')
  end

  test 'create issue relations if related issue exists' do
    @iip.update!(csv_data: "Subject,Tracker,Priority,Duplicates\ntest dup,Defect,Critical,#{@issue.id}\n")
    post :result, params: build_params.tap { |params| params[:fields_map] = params[:fields_map].merge('Duplicates' => 'duplicates') }
    assert Issue.find_by(subject: "test dup").relations.detect { |rel| rel.issue_to_id == @issue.id && rel.relation_type == "duplicates" }
  end

  test 'not create issue relations if related issue exists' do
    @iip.update!(csv_data: "#,Subject,Tracker,Priority,Duplicates\n4423,test dup,Defect,Critical,#{@issue.id}\n")
    other_issue = Issue.create!(@issue.slice(:tracker, :project, :status, :priority, :author).merge(id: 4423, subject: 'test dup'))
    IssueRelation.create!(issue_from: other_issue, issue_to: @issue, relation_type: 'duplicates')
    assert IssueRelation.count == 1
    post :result, params: build_params(update_issue: 'true').tap { |params| params[:fields_map] = params[:fields_map].merge('Duplicates' => 'duplicates') }
    assert IssueRelation.count == 1
  end

  test 'custom field can be used as a unique attr' do
    @iip.update!(csv_data: "Subject,Priority,Tracker,Affected versions\ntest unique,Critical,Defect,0.0.1\n")
    version = @project.versions.create!(name: '0.0.1')
    @issue.reload.custom_field_values
    @issue.custom_value_for(CustomField.find_by(name: 'Affected versions')).update!(value: version)
    post :result, params: build_params(update_issue: true, unique_field: 'Affected versions')
    assert @issue.reload.subject == 'test unique'
  end

  # errors

  test 'No import is currently in progress' do
    @iip.destroy
    post :result, params: { project_id: @project.id }
    assert flash[:error].include?('No import is currently in progress')
  end

  test 'another import started' do
    post :result, params: build_params(import_timestamp: @iip.created.strftime("%Y-%m-%d %H:%M:%S").next)
    assert flash[:error].include?('You seem to have started another import since starting this one. This import cannot be completed')
  end

  test 'update existing issues but unique field is empty' do
    post :result, params: build_params(update_issue: 'true', unique_field: nil)
    assert flash[:error].include?('Unique field must be specified because Update existing issues is on')
  end

  test 'parent issue field is selected but unique field is not selected' do
    post :result, params: build_params(unique_field: nil).tap { |params| params[:fields_map] = params[:fields_map].merge('Watchers' => 'parent_issue') }
    assert flash[:error].include?('Unique field must be specified because the column Parent task needs to refer to other tasks')
  end

  test 'related issue field is selected but unique field is not selected' do
    post :result, params: build_params(unique_field: nil).tap { |params| params[:fields_map] = params[:fields_map].merge('Watchers' => 'duplicates') }
    assert flash[:error].include?('Unique field must be specified because the column Is duplicate of needs to refer to other tasks')
  end

  test 'check "Import using issue ids" but id field is not selected' do
    post :result, params: build_params(use_issue_id: 'true').tap { |params| params[:fields_map].delete('#') }
    assert flash[:error].include?('You must specify a column mapping for id when importing using provided issue ids.')
  end

  test 'date format is invalid' do
    @iip.update!(csv_data: "Subject,Tracker,Status,Priority,StartDate\nHi,Defect,New,Critical,INVALID_START_DATE\n")
    post :result, params: build_params.tap { |params| params[:fields_map]['StartDate'] = 'start_date' }
    assert Issue.count == 1
    assert response.body.include?('Warning: When adding issue 1 below, INVALID_START_DATE is not valid value.')
  end

  test 'the issue id is already taken' do
    @issue.update!(id: 4423)
    @iip.update!(csv_data: "#,Subject,Tracker,Status,Priority\n4423,Hi,Defect,New,Critical\n")
    post :result, params: build_params(use_issue_id: 'true')
    assert Issue.count == 1
    assert response.body.include?('This issue id has already been taken.')
    assert response.body.include?('Warning: The following data-validation errors occurred on issue 1 in the list below')
  end

  test 'issue validation failed' do
    @iip.update!(csv_data: "Subject,Tracker,Status,Priority,StartDate,DueDate\nHi,Defect,New,Critical,2019-07-02,2019-07-01\n")
    post :result, params: build_params.tap { |params|
      params[:fields_map]['StartDate'] = 'start_date'
      params[:fields_map]['DueDate'] = 'due_date'
    }
    assert Issue.count == 1
    assert response.body.include?('Error: due_date must be greater than start date')
  end

  test 'try to update issue, but unique attr not found' do
    @iip.update!(csv_data: "Subject,Priority\ntest unique,Critical\n")
    post :result, params: build_params(update_issue: true, unique_field: 'Subject')
    assert response.body.include?('Warning: Could not update issue 1 below, no match for the value test unique were found')
  end

  # match action
  test 'File not attached' do
    post :match, params: build_match_params
    assert flash[:error] == 'CSV file is blank.'
  end

  test 'No data line' do
    post :match, params: build_match_params(file: create_csv_file(''))
    assert flash[:error].include?('No data line in your CSV, check the encoding of the file')
  end

  test 'Mulformed CSV' do
    file = create_csv_file(<<-CSV.strip_heredoc)
    Unclosed,quoted,field
    "unclosed,quoted,field
    CSV
    post :match, params: build_match_params(file: file)
    assert flash[:error].include?('Unclosed quoted field in line')
  end

  test 'Column header missing' do
    file = create_csv_file("one\ntwo,three?\n")
    post :match, params: build_match_params(file: file)
    assert flash[:error].include?('Column header missing')
  end

  test 'attributes mapped' do
    file = create_csv_file(<<-CSV.strip_heredoc)
    Subject
    hi
    CSV
    post :match, params: build_match_params(file: file)
    assert_response :success
    assert flash[:error].nil?
  end

  protected

  def build_params(opts={})
    @iip.reload
    opts.reverse_merge(
      :import_timestamp => @iip.created.strftime("%Y-%m-%d %H:%M:%S"),
      :unique_field => '#',
      :project_id => @project.id,
      :fields_map => {
        '#' => 'id',
        'Subject' => 'subject',
        'Tags' => 'Tags',
        'Affected versions' => 'Affected versions',
        'Priority' => 'priority',
        'Tracker' => 'tracker',
        'Status' => 'status',
        'Watchers' => 'watchers',
        'Area' => 'Area'
      }
    )
  end

  def build_match_params(opts = {})
    opts.reverse_merge(encoding: 'U', splitter: ',', wrapper: '"', project_id: @project.id)
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
    user = User.new :admin => true,
                    :login => 'bob',
                    :firstname => 'Bob',
                    :lastname => 'Loblaw',
                    :mail => 'bob.loblaw@example.com'
    user.login = 'bob'
    sponsor = User.new :admin => true,
                       :firstname => 'A',
                       :lastname => 'H',
                       :mail => 'a@example.com'
    sponsor.login = 'alice'

    membership = user.memberships.build(:project => project)
    membership.roles << role
    membership.principal = user

    membership = sponsor.memberships.build(:project => project)
    membership.roles << role
    membership.principal = sponsor
    sponsor.save!
    user.save!
    user
  end

  def create_iip_for_multivalues!(user, project)
    create_iip!('CustomFieldMultiValues', user, project)
  end

  def create_iip!(filename, user, project)
    iip = ImportInProgress.new
    iip.user = user
    iip.csv_data = get_csv(filename)
    #iip.created = DateTime.new(2001,2,3,4,5,6,'+7')
    iip.created = DateTime.now
    iip.encoding = 'U'
    iip.col_sep = ','
    iip.quote_char = '"'
    iip.save!
    iip
  end

  def create_issue!(project, author)
    issue = Issue.new
    issue.id = 70385
    issue.project = project
    issue.subject = 'foobar'
    issue.create_priority!(name: 'Critical')
    issue.tracker = project.trackers.first
    issue.author = author
    issue.status = IssueStatus.find_or_create_by!(name: 'New')
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
                                              %w(tag1 tag2))
    keyval_field = create_enumeration_field!('Area',
                                            issue.project,
                                            %w(Tokyo Osaka))
    issue.tracker.custom_fields << versions_field
    issue.tracker.custom_fields << multival_field
    issue.tracker.custom_fields << keyval_field
    issue.tracker.save!
  end

  def create_multivalue_field!(name, format, project, possible_vals = [])
    field = IssueCustomField.new :name => name, :multiple => true
    field.field_format = format
    field.projects << project
    field.possible_values = possible_vals if possible_vals
    field.save!
    field
  end

  def create_enumeration_field!(name, project, enumerations)
    field = IssueCustomField.new :name => name, :multiple => true, :field_format => 'enumeration'
    field.projects << project
    field.save!
    enumerations.each.with_index(1) do |name, position|
      CustomFieldEnumeration.create!(:name => name, :custom_field_id => field.id, :active => true, :position => position)
    end
    field
  end

  def create_versions!(project)
    project.versions.create! :name => 'Admin', :status => 'open'
    project.versions.create! :name => '2013-09-25', :status => 'open'
  end

  def get_csv(filename)
    File.read(File.expand_path("../../samples/#{filename}.csv", __FILE__))
  end

  def create_csv_file(content)
    file = Tempfile.new(['', '.csv'])
    file.write(content)
    file.flush
    Rack::Test::UploadedFile.new(file, 'text/csv')
  end
end
