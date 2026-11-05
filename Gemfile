# frozen_string_literal: true

source 'https://rubygems.org'

group :rubocop do
  gem 'rubocop', '~> 1.92.2'
  gem 'rubocop-performance'
  gem 'rubocop-rake'
  gem 'rubocop-rspec'
end

group :test do
  gem 'choria-mcorpc-support', '>= 2.28.0', require: false
  gem 'rake', require: false
  gem 'rspec', require: false
end

group :release, optional: true do
  gem 'faraday-retry', '~> 2.1', require: false
  gem 'github_changelog_generator', '~> 1.18', require: false
  gem 'puppet-blacksmith', '~> 9.1', require: false
end
