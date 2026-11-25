# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'rake'
require 'tmpdir'

load File.expand_path('../../rakelib/release.rake', __dir__)

RSpec.describe 'rake release:check' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:version) { JSON.parse(File.read(File.join(root, 'metadata.json')))['version'] }

  # The task reads metadata.json in the working directory, so every example
  # runs on a copy in a temporary directory.
  around do |example|
    Dir.mktmpdir('file_transfer-spec') do |dir|
      FileUtils.cp(File.join(root, 'metadata.json'), dir)
      Dir.chdir(dir) { example.run }
    end
  end

  def check(*arguments)
    task = Rake::Task['release:check']
    task.reenable
    task.invoke(*arguments)
  end

  def mismatch_message(argument)
    %(metadata.json contains version "#{version}", not "#{argument}". Merge the release pull request first.)
  end

  it 'passes without output when the argument is the version in metadata.json' do
    expect { expect { check(version) }.not_to raise_error }.to output('').to_stdout.and output('').to_stderr
  end

  it 'aborts naming both versions when the argument is another version' do
    message = mismatch_message(version.succ)

    expect { expect { check(version.succ) }.to raise_error(SystemExit, message) }.to output("#{message}\n").to_stderr
  end

  it 'aborts naming an empty version when the argument is missing' do
    message = mismatch_message('')

    expect { expect { check }.to raise_error(SystemExit, message) }.to output("#{message}\n").to_stderr
  end
end
