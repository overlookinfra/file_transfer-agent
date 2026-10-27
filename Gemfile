# frozen_string_literal: true

source 'https://rubygems.org'

group :rubocop do
  gem 'rubocop', '~> 1.86.0'
  gem 'rubocop-performance'
  gem 'rubocop-rake'
  gem 'rubocop-rspec'
end

group :test do
  # The gems that choria-mcorpc-support requires without declaring them,
  # which Ruby 3.4 and 4.0 no longer load from the standard library.
  gem 'base64', require: false
  gem 'choria-mcorpc-support', require: false
  gem 'logger', require: false
  gem 'rake', require: false
  gem 'rspec', require: false
end
