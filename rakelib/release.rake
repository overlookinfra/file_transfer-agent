# frozen_string_literal: true

require 'json'
require_relative 'lib/release_notes'

def module_version
  JSON.parse(File.read('metadata.json'))['version']
end

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
    config.future_release = module_version
  end
end

desc 'Prepare a release'
task 'release:prepare' => [:changelog]

desc 'Check that metadata.json contains the version that is to be released'
task 'release:check', [:version] do |_, args|
  version = module_version
  wanted = args[:version].to_s
  abort "metadata.json contains version #{version.inspect}, not #{wanted.inspect}. Merge the release pull request first." unless version == wanted
end

desc 'Create the signed tag of the version in metadata.json and push it'
task 'release:tag' do
  version = module_version
  sh 'git', 'tag', '-s', '-m', "Release #{version}", version
  sh 'git', 'push', 'origin', version
end

desc 'Create the GitHub release of the version in metadata.json with the module package in pkg/'
task 'release:github' do
  packages = Dir['pkg/*.tar.gz']
  abort 'No module package in pkg/. Build it with rake module:build.' if packages.empty?
  version = module_version
  changelog = File.exist?('CHANGELOG.md') ? File.read('CHANGELOG.md') : ''
  notes = ReleaseNotes.extract(changelog, version)
  warn "CHANGELOG.md has no notes for #{version}. The release gets the generated notes only." unless notes
  command = ['gh', 'release', 'create', version, '--title', version, '--generate-notes', '--verify-tag', '--latest']
  command += ['--notes', notes] if notes
  sh(*command, *packages)
end
