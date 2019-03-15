require 'rails_helper'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require f }

module CompatibleVerbs
  def get(path, env: {}, headers: {}, params: nil)
    super(path, params, env.merge(headers))
  end

  def post(path, env: {}, headers: {}, params: nil)
    super(path, params, env.merge(headers))
  end

  def patch(path, env: {}, headers: {}, params: nil)
    super(path, params, env.merge(headers))
  end

  def delete(path, env: {}, headers: {}, params: nil)
    super(path, params, env.merge(headers))
  end
end

RSpec.configure do |config|
  config.before :each do
    allow_any_instance_of(User).to receive(:deliver_security_notification).and_return nil
  end

  config.prepend CompatibleVerbs, type: :controller if Rails::VERSION::MAJOR < 5
end
