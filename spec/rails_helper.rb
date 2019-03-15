require File.expand_path(File.dirname(__FILE__) + '/../../../spec/rails_helper')

Dir[File.dirname(__FILE__) + '/support/**/*.rb'].each do |f|
  require f
end

begin
  require 'simplecov'
  require Rails.root.join('test', 'coverage', 'html_formatter').to_s
  SimpleCov.formatter = Redmine::Coverage::HtmlFormatter
  SimpleCov.root(File.dirname(__FILE__) + '/..')
  SimpleCov.start 'rails'
rescue LoadError
  puts 'SimpleCov missing -> skip'
end

RSpec.configure do |config|
  config.order = :rand

  config.use_transactional_fixtures = false

  config.before do
    I18n.locale = 'en'
  end
end
