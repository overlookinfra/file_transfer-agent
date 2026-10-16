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
  let(:terminal_logger) { an_instance_of(described_class::TerminalLogger) }

  before do
    allow(application).to receive(:options).and_return(options)
    allow(application).to receive(:rpcclient).with('file_transfer').and_return(rpc_client)
    allow(MCollective::Util::FileTransfer::Client).to receive(:new).and_return(client)
  end

  def configure(command, source, destination, **settings)
    application.configuration.merge!(command: command, source: source, destination: destination, **settings)
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

    # mco's own --timeout cannot be told from its default of 5, which the
    # gem reads as unset, so the command has a flag of its own and leaves
    # the library's default alone otherwise.
    it 'leaves the rpc timeout to the library without --rpc-timeout, whatever mco\'s timeout is' do
      allow(client).to receive(:upload).and_return(successes([node1, node2], '/opt/app/app.tar'))
      expect(MCollective::Util::FileTransfer::Client).to receive(:new)
        .with(options, logger: terminal_logger).and_return(client)

      expect { run_main }.to output.to_stdout
    end

    it 'passes --rpc-timeout as the rpc timeout' do
      configure('upload', '/srv/app.tar', '/opt/app/app.tar', rpc_timeout: 60)
      allow(client).to receive(:upload).and_return(successes([node1, node2], '/opt/app/app.tar'))
      expect(MCollective::Util::FileTransfer::Client).to receive(:new)
        .with(options, logger: terminal_logger, rpc_timeout: 60).and_return(client)

      expect { run_main }.to output.to_stdout
    end

    it 'passes the size options through' do
      settings = { message_data_size: 65_536, upload_batch_size: 100 }
      configure('upload', '/srv/app.tar', '/opt/app/app.tar', **settings)
      allow(client).to receive(:upload).and_return(successes([node1, node2], '/opt/app/app.tar'))
      expect(MCollective::Util::FileTransfer::Client).to receive(:new)
        .with(options, logger: terminal_logger, message_data_size: 65_536, upload_batch_size: 100)
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

    it 'exits 3 when no node responded' do
      outcomes = [node1, node2].to_h { |node| [node, outcome_class.failure(node, :no_response, "No response from #{node} for file_transfer.stat")] }
      allow(client).to receive(:upload).and_return(outcomes)
      status = nil

      expect { status = run_main }.to output(a_string_including('2 nodes, 2 failed')).to_stdout
      expect(status).to eq(3)
    end

    it 'exits 2 when every node failed and one of them did respond' do
      outcomes = { node1 => outcome_class.failure(node1, :transfer_failed, 'file_transfer.put app.tar failed: No space left on device'),
                   node2 => outcome_class.failure(node2, :no_response, "No response from #{node2} for file_transfer.put app.tar") }
      allow(client).to receive(:upload).and_return(outcomes)
      status = nil

      expect { status = run_main }.to output(a_string_including('2 nodes, 2 failed')).to_stdout
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

    it 'fetches the source into a directory per node under the destination and reports each local path' do
      destination_dirs = { node1 => '/tmp/logs/node1.example.com', node2 => '/tmp/logs/node2.example.com' }
      expect(client).to receive(:download).with('/var/log/app.log', destination_dirs) do |_source, requested|
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

    context 'when a node answered discovery with a name that is not one plain name' do
      let(:discovered) { [node1, '../../etc/cron.d'] }

      it 'fetches from the rest, never joins that name to the destination, and reports that node as failed' do
        expect(client).to receive(:download).with('/var/log/app.log', { node1 => '/tmp/logs/node1.example.com' })
                                            .and_return(successes([node1], '/tmp/logs/node1.example.com/app.log'))
        status = nil

        expect { status = run_main }
          .to output(a_string_including('The node name "../../etc/cron.d" cannot be a directory under /tmp/logs', '2 nodes, 1 failed')).to_stdout
        expect(status).to eq(2)
      end
    end
  end

  describe 'the logger it gives the library' do
    let(:logger) { described_class::TerminalLogger.new }

    it 'prints a warning on stderr even with Ruby warnings off' do
      verbose = $VERBOSE
      $VERBOSE = nil
      begin
        expect { logger.warn("Skipping /srv/data/linked on #{node1}, a symbolic link to a directory") }
          .to output("Skipping /srv/data/linked on #{node1}, a symbolic link to a directory\n").to_stderr
      ensure
        $VERBOSE = verbose
      end
    end

    it 'sends a debug line to the MCollective log' do
      expect(MCollective::Log).to receive(:debug).with('Upload of /srv/app.tar to /opt/app/app.tar on 2 nodes')

      logger.debug('Upload of /srv/app.tar to /opt/app/app.tar on 2 nodes')
    end
  end

  describe 'the arguments' do
    let(:workdir) { Dir.mktmpdir('file_transfer-app') }

    after { FileUtils.remove_entry_secure(workdir) }

    it 'takes the command, the source, and the destination from the command line' do
      stub_const('ARGV', ['upload', '/srv/app.tar', '/opt/app/app.tar'])

      application.post_option_parser(application.configuration)

      expect(application.configuration).to include(command: 'upload', source: '/srv/app.tar', destination: '/opt/app/app.tar')
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

    it 'refuses --one and --limit-nodes, which would leave nodes out without a word' do
      options[:mcollective_limit_targets] = 1
      configure('download', '/var/log/app.log', workdir)

      expect { application.validate_configuration(application.configuration) }.to raise_error(RuntimeError, /--one, --limit-nodes and --batch/)
    end

    it 'refuses --batch, which the library would not honor' do
      options[:batch_size] = '10'
      configure('download', '/var/log/app.log', workdir)

      expect { application.validate_configuration(application.configuration) }.to raise_error(RuntimeError, /--batch options are not supported/)
    end

    # The library refuses these too, but only once discovery has run.
    [:rpc_timeout, :message_data_size, :upload_batch_size].each do |name|
      it "refuses a #{name} of zero before discovery" do
        configure('download', '/var/log/app.log', workdir, name => 0)

        expect { application.validate_configuration(application.configuration) }
          .to raise_error(RuntimeError, "The --#{name.to_s.tr('_', '-')} option must be above zero")
      end
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
