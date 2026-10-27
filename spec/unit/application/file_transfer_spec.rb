# frozen_string_literal: true

require 'spec_helper'
require File.expand_path('../../../files/mcollective/application/file_transfer', __dir__)

# The command runs the real library over the fake RPC client, so every
# transfer here goes through Client, Connection, Rpc and the transfer
# classes. Discovery is the gem's, so it stays a double.
RSpec.describe MCollective::Application::File_transfer do
  include_context 'with a download client'

  let(:application) { described_class.new }
  let(:discovered) { [node2, node1] }
  let(:discovery) { instance_double(MCollective::RPC::Client, discover: discovered) }
  let(:options) { { timeout: 5, filter: { 'identity' => [] } } }
  let(:source) { local_file('app.tar', 'tar bytes') }

  before do
    allow(application).to receive(:options).and_return(options)
    allow(application).to receive(:rpcclient).with('file_transfer').and_return(discovery)
  end

  def configure(command, source, destination, **settings)
    application.configuration.merge!(command: command, source: source, destination: destination, **settings)
  end

  # main ends the process, so its exit status is the result.
  def run_main
    application.main
  rescue SystemExit => e
    e.status
  end

  describe 'an upload' do
    before do
      configure('upload', source, '/opt/app/app.tar')
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
    end

    it 'sends the source to the destination on the discovered nodes in name order and reports each destination path' do
      status = nil

      expect { status = run_main }.to output(a_string_including("#{node1}: /opt/app/app.tar", "#{node2}: /opt/app/app.tar", '2 nodes, 0 failed')).to_stdout
      expect(status).to eq(0)
      expect(put_calls.map { |call| [call[:destination], call[:identities], decoded(call)] }).to eq([['/opt/app/app.tar', [node1, node2], 'tar bytes']])
    end

    # mco's own --timeout cannot be told from its default of 5, which the
    # gem reads as unset, so the command has a flag of its own and leaves
    # the library's default alone otherwise.
    it 'leaves the rpc timeout to the library without --rpc-timeout, whatever mco\'s timeout is' do
      expect { run_main }.to output.to_stdout

      expect(rpc.calls.map(&:last).uniq).to eq([300])
    end

    it 'passes --rpc-timeout as the rpc timeout' do
      configure('upload', source, '/opt/app/app.tar', rpc_timeout: 400)

      expect { run_main }.to output.to_stdout

      expect(rpc.calls.map(&:last).uniq).to eq([400])
    end

    it 'passes the size options through' do
      configure('upload', local_file('big.tar', 'x' * 102_400), '/opt/app/app.tar', message_data_size: 64, upload_batch_size: 100)

      expect { run_main }.to output.to_stdout

      expect(put_calls.map { |call| decoded(call).bytesize }).to eq([65_536, 36_864])
      expect(put_calls.map { |call| call[:batch_size] }.uniq).to eq([100])
    end

    it 'reports a failed node with the library message and exits 2' do
      stub_put do |args, names|
        names.map { |name| name == node2 && args[:final] ? rpc_result(name, {}, statuscode: 1, statusmsg: 'No space left on device') : rpc_result(name) }
      end
      status = nil

      expect { status = run_main }
        .to output(a_string_including("#{node2}: The file_transfer.put /opt/app/app.tar (final) call on #{node2} failed: No space left on device",
          '2 nodes, 1 failed')).to_stdout
      expect(status).to eq(2)
    end

    it 'exits 3 when no node responded' do
      stub_stat { |_args, _names| [] }
      status = nil

      expect { status = run_main }.to output(a_string_including('2 nodes, 2 failed')).to_stdout
      expect(status).to eq(3)
    end

    it 'exits 2 when every node failed and one of them did respond' do
      stub_stat { |_args, names| results_for(names - [node2], { exists: false }) }
      stub_put { |_args, names| results_for(names, statuscode: 1, statusmsg: 'No space left on device') }
      status = nil

      expect { status = run_main }.to output(a_string_including('2 nodes, 2 failed')).to_stdout
      expect(status).to eq(2)
    end

    context 'when interrupted during the transfer' do
      # Ruby's own handler, which raises the Interrupt that the gem
      # swallows, is the one in place before main, and RSpec's is put back
      # after the example.
      around do |example|
        rspec_handler = Signal.trap('INT', 'DEFAULT')
        example.run
      ensure
        Signal.trap('INT', rspec_handler)
      end

      it 'stops at a Ctrl-C, which the gem would swallow as an Interrupt, and puts the previous handler back' do
        stub_put do |_args, _names|
          Process.kill('INT', Process.pid)
          sleep 5
        rescue Interrupt
          # What the gem's request loop does with an interrupt.
          :carried_on
        end

        expect { run_main }.to raise_error(SignalException, 'SIGINT')
        expect(Signal.trap('INT', 'DEFAULT')).to eq('DEFAULT')
      end
    end

    context 'when no node matches the filter' do
      let(:discovered) { [] }

      it 'says so and exits 1' do
        status = nil

        expect { status = run_main }.to output(a_string_including('No nodes matched the filter')).to_stdout
        expect(status).to eq(1)
      end
    end
  end

  describe 'a download' do
    before do
      configure('download', '/var/log/app.log', destination)
      stub_file_stats
      stub_get
    end

    it 'fetches the source into a directory per node under the destination and reports each local path' do
      status = nil

      expect { status = run_main }.to output(a_string_including("#{node1}: #{File.join(dir_for(node1), 'app.log')}", '2 nodes, 0 failed')).to_stdout
      expect(status).to eq(0)
      expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq(contents[node1])
      expect(File.binread(File.join(dir_for(node2), 'app.log'))).to eq(contents[node2])
    end

    it 'creates the destination directory when it does not exist yet' do
      fresh = File.join(workdir, 'fresh')
      configure('download', '/var/log/app.log', fresh)

      expect { run_main }.to output(a_string_including('2 nodes, 0 failed')).to_stdout

      expect(File.binread(File.join(fresh, node1, 'app.log'))).to eq(contents[node1])
    end

    it 'counts a single node in the singular' do
      allow(discovery).to receive(:discover).and_return([node1])

      expect { run_main }.to output(a_string_including('1 node, 0 failed')).to_stdout
    end

    context 'when a node answered discovery with a name that is not one plain name' do
      let(:discovered) { [node1, '../../etc/cron.d'] }

      it 'fetches from the rest, never joins that name to the destination, and reports that node as failed' do
        status = nil

        expect { status = run_main }
          .to output(a_string_including("The node name \"../../etc/cron.d\" cannot be a directory under #{destination}", '2 nodes, 1 failed')).to_stdout
        expect(status).to eq(2)
        expect(rpc.calls.map { |call| call[2] }.uniq).to eq([[node1]])
        expect(Dir.children(destination)).to eq([node1])
      end
    end
  end

  describe 'the logger it gives the library' do
    let(:logger) { described_class::TerminalLogger.new }

    it 'sends a warning to the MCollective log and prints it on stderr even with Ruby warnings off' do
      message = "Skipping /srv/data/linked on #{node1}, a symbolic link to a directory"
      expect(MCollective::Log).to receive(:warn).with(message)
      verbose = $VERBOSE
      $VERBOSE = nil
      begin
        expect { logger.warn(message) }.to output("#{message}\n").to_stderr
      ensure
        $VERBOSE = verbose
      end
    end

    it 'sends an error to the MCollective log and prints it on stderr' do
      message = 'The file_transfer.stat /srv/data RPC call failed: RuntimeError: broker down'
      expect(MCollective::Log).to receive(:error).with(message)

      expect { logger.error(message) }.to output("#{message}\n").to_stderr
    end

    it 'sends a debug line to the MCollective log alone' do
      expect(MCollective::Log).to receive(:debug).with('Each message contains up to 524288 bytes of data')

      expect { logger.debug('Each message contains up to 524288 bytes of data') }.not_to output.to_stderr
    end

    it 'sends an info line to the MCollective log alone' do
      expect(MCollective::Log).to receive(:info).with('Upload of /srv/app.tar to /opt/app/app.tar on 2 nodes')

      expect { logger.info('Upload of /srv/app.tar to /opt/app/app.tar on 2 nodes') }.not_to output.to_stderr
    end
  end

  describe 'the arguments' do
    it 'takes the command, the source, and the destination from the command line' do
      stub_const('ARGV', ['upload', '/srv/app.tar', '/opt/app/app.tar'])

      application.post_option_parser(application.configuration)

      expect(application.configuration).to include(command: 'upload', source: '/srv/app.tar', destination: '/opt/app/app.tar')
    end

    it 'refuses a command line without all 3' do
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
      File.write(File.join(workdir, 'file'), '')
      configure('download', '/var/log/app.log', File.join(workdir, 'file'))

      expect { application.validate_configuration(application.configuration) }.to raise_error(RuntimeError, /is not a directory/)
    end

    it 'accepts a download into a directory that does not exist yet' do
      configure('download', '/var/log/app.log', File.join(workdir, 'missing'))

      expect { application.validate_configuration(application.configuration) }.not_to raise_error
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

    it 'raises the client\'s ArgumentError for a setting of 0 before discovering any node' do
      configure('download', '/var/log/app.log', workdir, message_data_size: 0)
      expect(application).not_to receive(:rpcclient)

      expect { application.main }.to raise_error(ArgumentError, 'The message_data_size setting must be an integer above 0, not 0')
    end

    it 'accepts an upload of an existing file and a download into an existing directory' do
      configure('upload', source, '/opt/app/app.tar')
      expect { application.validate_configuration(application.configuration) }.not_to raise_error

      configure('download', '/var/log/app.log', workdir)
      expect { application.validate_configuration(application.configuration) }.not_to raise_error
    end
  end
end
