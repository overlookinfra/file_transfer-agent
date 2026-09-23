# frozen_string_literal: true

require 'spec_helper'
require File.expand_path('../../../files/mcollective/application/file_transfer', __dir__)

RSpec.describe MCollective::Application::File_transfer do
  let(:application) { described_class.new }
  let(:node1) { 'node1.example.com' }
  let(:node2) { 'node2.example.com' }
  let(:discovered) { [node2, node1] }
  let(:rpc_client) { instance_double(MCollective::RPC::Client, discover: discovered) }
  let(:client) { instance_double(MCollective::Util::FileTransfer::Client) }
  let(:options) { { timeout: 5, filter: { 'identity' => [] } } }
  let(:outcome_class) { MCollective::Util::FileTransfer::Outcome }

  before do
    allow(application).to receive(:options).and_return(options)
    allow(application).to receive(:rpcclient).with('file_transfer').and_return(rpc_client)
    allow(MCollective::Util::FileTransfer::Connection).to receive(:new).with(options).and_return(:connection)
    allow(MCollective::Util::FileTransfer::Client).to receive(:new).and_return(client)
  end

  def configure(command, source, target, **settings)
    application.configuration.merge!(command: command, source: source, target: target, **settings)
  end

  # main ends the process, so its exit status is the answer.
  def run_main
    application.main
  rescue SystemExit => e
    e.status
  end

  def successes(identities, path)
    identities.to_h { |identity| [identity, outcome_class.success(identity, path)] }
  end

  describe 'an upload' do
    before { configure('upload', '/srv/app.tar', '/opt/app/app.tar') }

    it 'sends the source to the destination on the discovered nodes in name order and reports each landing path' do
      expect(client).to receive(:upload).with('/srv/app.tar', '/opt/app/app.tar', [node1, node2]).and_return(successes([node1, node2], '/opt/app/app.tar'))
      status = nil

      expect { status = run_main }.to output(a_string_including("#{node1}: /opt/app/app.tar", "#{node2}: /opt/app/app.tar", '2 nodes, 0 failed')).to_stdout
      expect(status).to eq(0)
    end

    it 'builds the client from the mco options with the timeout as the rpc timeout and cleanup on' do
      allow(client).to receive(:upload).and_return(successes([node1, node2], '/opt/app/app.tar'))
      expect(MCollective::Util::FileTransfer::Client).to receive(:new).with(connection: :connection, rpc_timeout: 5, cleanup: true).and_return(client)

      expect { run_main }.to output.to_stdout
    end

    it 'passes the size options through and keeps the session when asked' do
      settings = { chunk_size: 65_536, upload_batch_size: 100, download_group_size: 4, keep_session: true }
      configure('upload', '/srv/app.tar', '/opt/app/app.tar', **settings)
      allow(client).to receive(:upload).and_return(successes([node1, node2], '/opt/app/app.tar'))
      expect(MCollective::Util::FileTransfer::Client).to receive(:new)
        .with(connection: :connection, rpc_timeout: 5, cleanup: false, chunk_size: 65_536, upload_batch_size: 100, download_group_size: 4)
        .and_return(client)

      expect { run_main }.to output.to_stdout
    end

    it 'reports a failed node with the library message and exits 2' do
      outcomes = { node1 => outcome_class.success(node1, '/opt/app/app.tar'),
                   node2 => outcome_class.failure(node2, :transfer_failed, 'file_transfer.put app.tar (final) on node2.example.com failed: No space left on device') }
      allow(client).to receive(:upload).and_return(outcomes)
      status = nil

      expect { status = run_main }.to output(a_string_including("#{node2}: file_transfer.put app.tar (final)", 'No space left on device', '2 nodes, 1 failed')).to_stdout
      expect(status).to eq(2)
    end

    context 'when no node matches the filter' do
      let(:discovered) { [] }

      it 'says so, exits 1, and builds no client' do
        expect(MCollective::Util::FileTransfer::Client).not_to receive(:new)
        status = nil

        expect { status = run_main }.to output(a_string_including('No nodes matched the filter')).to_stdout
        expect(status).to eq(1)
      end
    end
  end

  describe 'a download' do
    before { configure('download', '/var/log/app.log', '/tmp/logs') }

    it 'fetches the source into a directory per node under the target and reports each local path' do
      directories = { node1 => '/tmp/logs/node1.example.com', node2 => '/tmp/logs/node2.example.com' }
      expect(client).to receive(:download).with('/var/log/app.log', directories) do |_source, requested|
        requested.to_h { |identity, directory| [identity, outcome_class.success(identity, File.join(directory, 'app.log'))] }
      end
      status = nil

      expect { status = run_main }.to output(a_string_including("#{node1}: /tmp/logs/node1.example.com/app.log", '2 nodes, 0 failed')).to_stdout
      expect(status).to eq(0)
    end

    it 'counts a single node in the singular' do
      allow(rpc_client).to receive(:discover).and_return([node1])
      allow(client).to receive(:download).and_return(successes([node1], '/tmp/logs/node1.example.com/app.log'))

      expect { run_main }.to output(a_string_including('1 node, 0 failed')).to_stdout
    end
  end

  describe 'the arguments' do
    let(:workdir) { Dir.mktmpdir('file_transfer-app') }

    after { FileUtils.remove_entry_secure(workdir) }

    it 'takes the command, the source, and the destination from the command line' do
      stub_const('ARGV', ['upload', '/srv/app.tar', '/opt/app/app.tar'])

      application.post_option_parser(application.configuration)

      expect(application.configuration).to include(command: 'upload', source: '/srv/app.tar', target: '/opt/app/app.tar')
    end

    it 'refuses a command line without all three' do
      stub_const('ARGV', ['upload', '/srv/app.tar'])

      expect { application.post_option_parser(application.configuration) }.to raise_error(RuntimeError, /upload or download, a source, and a destination/)
    end

    it 'refuses a command that is not upload or download' do
      configure('copy', '/srv/app.tar', '/opt/app/app.tar')

      expect { application.validate_configuration(application.configuration) }.to raise_error(RuntimeError, /must be upload or download/)
    end

    it 'refuses an upload of a source that does not exist' do
      configure('upload', File.join(workdir, 'missing.tar'), '/opt/app/app.tar')

      expect { application.validate_configuration(application.configuration) }.to raise_error(RuntimeError, /missing.tar does not exist/)
    end

    it 'refuses a download into something that is not a directory' do
      configure('download', '/var/log/app.log', File.join(workdir, 'missing'))

      expect { application.validate_configuration(application.configuration) }.to raise_error(RuntimeError, /is not a directory/)
    end

    it 'accepts an upload of an existing file and a download into an existing directory' do
      source = File.join(workdir, 'app.tar')
      File.write(source, 'tar')
      configure('upload', source, '/opt/app/app.tar')
      expect { application.validate_configuration(application.configuration) }.not_to raise_error

      configure('download', '/var/log/app.log', workdir)
      expect { application.validate_configuration(application.configuration) }.not_to raise_error
    end
  end
end
