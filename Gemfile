source 'https://rubygems.org'

group :development do
  gem 'rspec',               '~> 3.7'
  gem 'json-schema',         '~> 2.8'
  gem 'rake',                '~> 12.3'
  gem 'yard',                '~> 0.9.12'
end

if File.exists? "#{__FILE__}.local"
  eval(File.read("#{__FILE__}.local"), binding)
end
