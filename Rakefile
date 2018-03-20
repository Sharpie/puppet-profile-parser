require 'rspec/core/rake_task'

namespace(:spec) do
  desc 'Run RSpec unit tests'
  RSpec::Core::RakeTask.new(:unit) do |task|
    task.pattern = 'spec/unit/**{,/*/**}/*_spec.rb'
  end
end

desc 'Run all test suites'
task(:test => ['spec:unit'])


require 'yard'
require 'yard/rake/yardoc_task'

yard = YARD::Rake::YardocTask.new(:doc)
