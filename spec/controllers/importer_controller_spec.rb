require File.expand_path(File.dirname(__FILE__) + '/../rails_helper')

describe ImporterController, type: :controller do
  let(:user) { create :user, admin: true }
  let(:tracker) { create :tracker }
  let(:project) { create :project, trackers: [tracker] }
  let(:issue) { create :issue, project: project, tracker: tracker }
  let!(:issue_custom_field) do
    create :issue_custom_field,
           :enumeration,
           is_for_all: true,
           trackers: [tracker],
           name: 'KeyValue'
  end

  before do
    login_as(user)
  end

  describe 'handle_custom_fields' do
    let(:change_enumeration) { issue_custom_field.enumerations[0] }
    let(:row) { { Id: 1, KeyValue: change_enumeration.name }.stringify_keys }
    subject do
      attrs_map = {
        'id': 'Id',
        'KeyValue': 'KeyValue'
      }.stringify_keys
      controller = ImporterController.new
      controller.instance_variable_set(:@attrs_map, attrs_map)
      controller.handle_custom_fields(true, issue, project, row)
    end

    it 'KeyValue型の値が更新される' do
      expect { subject }.to change {
        issue.custom_field_values[0].value
      }.from(nil).to(change_enumeration.id.to_s)
    end
  end
end
