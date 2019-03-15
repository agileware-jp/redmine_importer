RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each) do
    DatabaseCleaner.strategy = :transaction
  end

  config.before(:each, js: true) do
    DatabaseCleaner.strategy = :deletion
  end

  config.before(:each) do
    DatabaseCleaner.start
  end

  config.after(:each) do
    begin
      DatabaseCleaner.clean
    rescue ActiveRecord::StatementInvalid => e
      # With SQLite3, deletion strategy and feature specs, BusyException occurs at times.
      raise e unless e.message.include?('SQLite3::BusyException: database is locked: DELETE FROM')

      sleep 3
      puts 'Retry cleaning'
      DatabaseCleaner.clean
    end
  end
end
