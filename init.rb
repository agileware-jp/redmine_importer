# frozen_string_literal: true

require 'redmine'

paths = [
  File.expand_path('../app/models', __FILE__),
  File.expand_path('../app/controllers', __FILE__)
]

if Rails.version.to_f >= 7.0
  Rails.application.config.before_initialize do
    paths.each { |p| Rails.autoloaders.main.push_dir(p) }
  end
else
  paths.each { |p| ActiveSupport::Dependencies.autoload_paths << p }
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
