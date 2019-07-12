require File.expand_path('../../test_helper', __FILE__)
require 'application_system_test_case'

class ImportTest < ApplicationSystemTestCase
  driven_by :selenium

  fixtures :users, :projects, :trackers, :projects_trackers, :enumerations, :issue_statuses, :custom_fields

  def setup
    sign_in
    click_on 'Import'
  end

  test 'import all standard fields' do
    attach_file 'file', File.expand_path('../../samples/AllStandardFields.csv', __FILE__)
    click_on 'Upload File'
    assert page.has_content?('Refer to top lines of AllStandardFields.csv')
    click_on 'Submit'
    assert page.has_content?('1 issues processed. 1 issues successfully imported.')
  end

  private

  def sign_in
    visit '/'
    click_on 'Sign in'
    fill_in 'Login', with: 'admin'
    fill_in 'Password', with: 'admin'
    click_on 'Login'
    click_on 'Projects'
    click_on 'eCookbook'
    click_on 'Settings'
    check 'Importer'
    click_on 'Save'
  end

  def create_csv_file(content)
    file = Tempfile.new(['', '.csv'])
    file.write(content)
    file.close
    file
  end
end
