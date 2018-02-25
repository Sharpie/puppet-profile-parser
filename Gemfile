source 'https://rubygems.org'

gem 'terminal-table'

group :development do
  gem 'rspec', '~> 3.7'
  gem 'rake',  '~> 12.3'
end

if File.exists? "#{__FILE__}.local"
  eval(File.read("#{__FILE__}.local"), binding)
end
