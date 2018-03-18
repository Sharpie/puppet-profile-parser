PROJECT_ROOT = File.expand_path('..', File.dirname(__FILE__)).freeze
SPEC_ROOT = File.expand_path(File.dirname(__FILE__)).freeze

require 'json-schema'

module TestHelpers
  def fixture(name)
    File.join(SPEC_ROOT, 'fixtures', name)
  end
end

RSpec.configure do |config|
  config.include TestHelpers
end
