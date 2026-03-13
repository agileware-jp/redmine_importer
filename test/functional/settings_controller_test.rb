# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ImporterSettingsControllerTest < ActionController::TestCase
  include ActiveJob::TestHelper

  tests SettingsController

  def setup
    ActionController::Base.allow_forgery_protection = false
    @request.session[:user_id] = 1 # admin from fixtures
  end

  test 'should reject empty max_csv_rows' do
    post :plugin, params: { id: 'redmine_importer', settings: { 'max_csv_rows' => '' } }
    assert_redirected_to plugin_settings_path('redmine_importer')
    assert_equal I18n.t(:error_max_csv_rows_invalid), flash[:error]
  end

  test 'should reject non-numeric max_csv_rows' do
    post :plugin, params: { id: 'redmine_importer', settings: { 'max_csv_rows' => 'abc' } }
    assert_redirected_to plugin_settings_path('redmine_importer')
    assert_equal I18n.t(:error_max_csv_rows_invalid), flash[:error]
  end

  test 'should reject zero max_csv_rows' do
    post :plugin, params: { id: 'redmine_importer', settings: { 'max_csv_rows' => '0' } }
    assert_redirected_to plugin_settings_path('redmine_importer')
    assert_equal I18n.t(:error_max_csv_rows_invalid), flash[:error]
  end

  test 'should reject negative max_csv_rows' do
    post :plugin, params: { id: 'redmine_importer', settings: { 'max_csv_rows' => '-5' } }
    assert_redirected_to plugin_settings_path('redmine_importer')
    assert_equal I18n.t(:error_max_csv_rows_invalid), flash[:error]
  end

  test 'should reject decimal max_csv_rows' do
    post :plugin, params: { id: 'redmine_importer', settings: { 'max_csv_rows' => '3.14' } }
    assert_redirected_to plugin_settings_path('redmine_importer')
    assert_equal I18n.t(:error_max_csv_rows_invalid), flash[:error]
  end

  test 'should accept valid positive integer max_csv_rows' do
    post :plugin, params: { id: 'redmine_importer', settings: { 'max_csv_rows' => '1000' } }
    assert_redirected_to plugin_settings_path('redmine_importer')
    assert_equal I18n.t(:notice_successful_update), flash[:notice]
    assert_equal '1000', Setting.plugin_redmine_importer['max_csv_rows']
  end
end
