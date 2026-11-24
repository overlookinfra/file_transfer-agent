# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'rake'
require 'tmpdir'

load File.expand_path('../../rakelib/vox.rake', __dir__)

VERSIONED_FILES = ['metadata.json', 'files/mcollective/agent/file_transfer.ddl', 'files/mcollective/agent/file_transfer.json'].freeze

RSpec.describe 'rake vox:version:bump:full' do
  let(:root) { File.expand_path('../..', __dir__) }

  # The task works on the files in the working directory, so every example
  # runs on copies in a temporary directory.
  around do |example|
    Dir.mktmpdir('file_transfer-spec') do |dir|
      VERSIONED_FILES.each do |path|
        FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
        FileUtils.cp(File.join(root, path), File.join(dir, path))
      end
      Dir.chdir(dir) { example.run }
    end
  end

  def bump(*arguments)
    task = Rake::Task['vox:version:bump:full']
    task.reenable
    task.invoke(*arguments)
  end

  it 'prints the version and writes it into the 3 files' do
    expect { bump('10.20.30') }.to output("Setting version to 10.20.30\n").to_stdout

    expect(JSON.parse(File.read('metadata.json'))['version']).to eq('10.20.30')
    expect(JSON.parse(File.read('files/mcollective/agent/file_transfer.json'))['metadata']['version']).to eq('10.20.30')
    expect(File.read('files/mcollective/agent/file_transfer.ddl')).to match(/^\s*:version\s+=> "10\.20\.30",$/)
  end

  it 'changes exactly 1 line in each file' do
    expect { bump('10.20.30') }.to output.to_stdout

    VERSIONED_FILES.each do |path|
      original_lines = File.readlines(File.join(root, path))
      new_lines = File.readlines(path)
      expect(new_lines.length).to eq(original_lines.length), path
      expect(original_lines.zip(new_lines).count { |original, new| original != new }).to eq(1), path
    end
  end

  {
    ['1.2'] => '"1.2" is not a version in x.y.z form',
    ['1.2.3-rc1'] => '"1.2.3-rc1" is not a version in x.y.z form',
    ['v1.2.3'] => '"v1.2.3" is not a version in x.y.z form',
    [] => '"" is not a version in x.y.z form',
  }.each do |arguments, message|
    it "aborts on the arguments #{arguments.inspect} and leaves the 3 files as they were" do
      expect { expect { bump(*arguments) }.to raise_error(SystemExit, message) }.to output("#{message}\n").to_stderr

      VERSIONED_FILES.each do |path|
        expect(File.binread(path)).to eq(File.binread(File.join(root, path))), path
      end
    end
  end

  VERSIONED_FILES.each do |path|
    it "aborts naming #{path} when it has no version line" do
      File.write(path, "{}\n")
      message = "No version found in #{path}"

      expect { expect { bump('10.20.30') }.to raise_error(SystemExit, message) }.to output("Setting version to 10.20.30\n").to_stdout.and output("#{message}\n").to_stderr
    end
  end
end
