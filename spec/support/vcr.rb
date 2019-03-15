VCR.configure do |c|
  c.cassette_library_dir = File.expand_path(File.dirname(__FILE__) + '/../vcr')
  c.hook_into :webmock
  c.ignore_localhost = true # https://github.com/vcr/vcr/issues/229
  c.allow_http_connections_when_no_cassette = false

  c.filter_sensitive_data '<MASKED>', :mask_request_body do |interaction|
    interaction.request.body
  end

  c.filter_sensitive_data 'Bearer <MASKED>' do |interaction|
    interaction.request.headers['Authorization'].try(:first)
  end

  c.configure_rspec_metadata!
end
