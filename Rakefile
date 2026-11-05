# frozen_string_literal: true

require 'json'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:test)

task default: :test

# The release gems are an optional bundle group, installed with
# bundle install --with release.
begin
  require 'puppet_blacksmith/rake_tasks'
  require 'github_changelog_generator/task'
rescue LoadError
  desc 'Generate CHANGELOG.md'
  task :changelog do
    abort('Run bundle install --with release to install the release gems.')
  end
else
  GitHubChangelogGenerator::RakeTask.new :changelog do |config|
    config.header = <<~HEADER.chomp
      # Changelog

      All notable changes to this project will be documented in this file.
    HEADER
    config.user = 'overlookinfra'
    config.project = 'file_transfer-agent'
    config.exclude_labels = %w[dependencies duplicate question invalid wontfix wont-fix skip-changelog]
    config.future_release = JSON.parse(File.read('metadata.json'))['version']
  end
end

desc 'Prepare a release'
task 'release:prepare' => [:changelog]

# Writes the version into one file and keeps the text around it.
def set_version(path, pattern, version)
  content = File.read(path)
  abort "No version found in #{path}" unless content.match?(pattern)
  File.write(path, content.sub(pattern) { "#{Regexp.last_match(1)}#{version}#{Regexp.last_match(2)}" })
end

namespace :vox do
  desc 'Set the module and agent version in every file that carries it'
  task 'version:bump:full', [:version] do |_, args|
    version = args[:version].to_s
    abort "#{version.inspect} is not a version in x.y.z form" unless version.match?(/\A\d+\.\d+\.\d+\z/)
    puts "Setting version to #{version}"
    set_version('metadata.json', /("version": ")[^"]+(")/, version)
    set_version('files/mcollective/agent/file_transfer.ddl', /(:version\s+=> ")[^"]+(")/, version)
    set_version('files/mcollective/agent/file_transfer.json', /("version": ")[^"]+(")/, version)
  end
end
