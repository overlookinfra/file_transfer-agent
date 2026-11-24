# frozen_string_literal: true

# Writes the version into one file and keeps the text around it.
def set_version(path, pattern, version)
  content = File.read(path)
  abort "No version found in #{path}" unless content.match?(pattern)
  File.write(path, content.sub(pattern) { "#{Regexp.last_match(1)}#{version}#{Regexp.last_match(2)}" })
end

namespace :vox do
  desc 'Set the module and agent version in every file that contains it'
  task 'version:bump:full', [:version] do |_, args|
    version = args[:version].to_s
    abort "#{version.inspect} is not a version in x.y.z form" unless version.match?(/\A\d+\.\d+\.\d+\z/)
    puts "Setting version to #{version}"
    set_version('metadata.json', /("version": ")[^"]+(")/, version)
    set_version('files/mcollective/agent/file_transfer.ddl', /(:version\s+=> ")[^"]+(")/, version)
    set_version('files/mcollective/agent/file_transfer.json', /("version": ")[^"]+(")/, version)
  end
end
