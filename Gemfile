source 'https://rubygems.org'

group :development do
  gem 'rspec',               '~> 3.7'
  # 2.6.2 was the last json-schema version with support for Ruby 2.0.
  gem 'json-schema',         '2.6.2'
  gem 'rake',                '~> 12.3'
  gem 'yard',                '~> 0.9.12'
end

if File.exists? "#{__FILE__}.local"
  eval(File.read("#{__FILE__}.local"), binding)
end
