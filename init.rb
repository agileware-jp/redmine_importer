# frozen_string_literal: true

# Load models and controllers before Rails initialization
base_path = File.expand_path('..', __FILE__)
app_path = File.join(base_path, 'app')
models_path = File.join(app_path, 'models')
controllers_path = File.join(app_path, 'controllers')

require File.join(models_path, 'import_in_progress')
require File.join(controllers_path, 'importer_controller')

# Load Redmine after models are loaded
require 'redmine'

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
