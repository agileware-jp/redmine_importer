require 'single_cov'
SingleCov.setup :minitest
SingleCov.covered!(file: 'plugins/redmine_importer/app/models/import_in_progress.rb')
SingleCov.covered!(file: 'plugins/redmine_importer/app/helpers/importer_helper.rb')
SingleCov.covered!(file: 'plugins/redmine_importer/app/controllers/importer_controller.rb')

require File.expand_path('../../../../test/test_helper', __FILE__)
