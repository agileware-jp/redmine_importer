# frozen_string_literal: true

require 'redmine'

Rails.application.config.after_initialize do
  # Ensure plugin classes are reloaded in development
  ActiveSupport::Dependencies.autoload_paths << File.expand_path('../app/models', __FILE__)
  ActiveSupport::Dependencies.autoload_paths << File.expand_path('../app/controllers', __FILE__)
end

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
