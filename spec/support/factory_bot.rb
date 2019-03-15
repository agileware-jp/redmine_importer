RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  FactoryBot.definition_file_paths = [File.dirname(__FILE__) + '/../factories/']
  config.before(:suite) do
    FactoryBot.find_definitions
  end
end
