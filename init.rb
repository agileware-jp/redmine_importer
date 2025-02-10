# frozen_string_literal: true

require 'redmine'

# Ensure plugin classes are loaded
base_path = File.expand_path('..', __FILE__)
app_path = File.join(base_path, 'app')
models_path = File.join(app_path, 'models')
controllers_path = File.join(app_path, 'controllers')

$LOAD_PATH.unshift(models_path, controllers_path) unless $LOAD_PATH.include?(models_path)
ActiveSupport::Dependencies.autoload_paths += [models_path, controllers_path]

require File.join(models_path, 'import_in_progress')
require File.join(controllers_path, 'importer_controller')

Redmine::Plugin.register :redmine_importer do
  name 'Issue Importer'
  author 'Martin Liu / Leo Hourvitz / Stoyan Zhekov / Jérôme Bataille / Agileware Inc.'
  description 'Issue import plugin for Redmine.'
  version '1.2.2'

  project_module :importer do
    permission :import, importer: :index
  end
  menu :project_menu,
       :importer,
       { controller: 'importer', action: 'index' },
       caption: :label_import,
       before: :settings,
       param: :project_id
end
