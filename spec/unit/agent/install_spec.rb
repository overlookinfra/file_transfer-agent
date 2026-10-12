# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'the file_transfer module as installed' do
  # The Choria server runs the agent file directly, so what the harness
  # bypasses by naming the interpreter has to hold for the committed file.
  describe 'the agent file' do
    it 'is executable' do
      expect(File.stat(AGENT).mode & 0o111).to eq(0o111)
    end

    it 'starts with an absolute shebang naming the Ruby that Puppet ships' do
      expect(File.new(AGENT).readline.chomp).to eq('#!/opt/puppetlabs/puppet/bin/ruby')
    end
  end

  # The Puppet module installs the files data/plugin.yaml lists and no
  # others, while the specs load the library straight from the repository.
  describe 'the list of files' do
    let(:plugin) { YAML.safe_load_file(File.expand_path('../../../data/plugin.yaml', __dir__)) }
    let(:plugin_root) { File.join(FILES_DIR, 'mcollective') }

    def listed(key)
      plugin.fetch("mcollective_agent_file_transfer::#{key}")
    end

    # The files that ship below the given directories, as plugin.yaml names them.
    def shipped(*directories)
      directories.flat_map do |directory|
        Dir.glob('**/*', base: File.join(plugin_root, directory))
           .map { |path| File.join(directory, path) }
           .select { |path| File.file?(File.join(plugin_root, path)) }
      end
    end

    it 'names every client file that ships and none that does not' do
      expect(listed('client_files')).to match_array(shipped('application', 'util'))
    end

    it 'names the directory the client library lives in' do
      expect(listed('client_directories')).to eq(['util/file_transfer'])
    end

    it 'names every agent file that ships among the server and common files' do
      expect(listed('server_files') + listed('common_files')).to match_array(shipped('agent'))
    end

    it 'marks the agent script as the one executable' do
      expect(listed('executable_files')).to eq(['agent/file_transfer'])
    end
  end
end
