# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Client do
  include_context 'with a download client'

  describe 'the timeout and the sizes it is given' do
    [0, -1, 1.5, '16'].each do |value|
      it "refuses #{value.inspect} as the rpc timeout" do
        expect { described_class.new({}, logger: log, rpc_timeout: value) }
          .to raise_error(ArgumentError, "The rpc_timeout setting must be an integer above 0, not #{value.inspect}")
      end
    end

    [:message_data_size, :upload_batch_size].each do |size|
      it "refuses 0 as the #{size}" do
        expect { described_class.new({}, logger: log, size => 0) }.to raise_error(ArgumentError, "The #{size} setting must be an integer above 0, not 0")
      end
    end
  end

  describe 'the gem it runs on' do
    it 'refuses a choria-mcorpc-support older than the library needs, before any call' do
      installed = Gem.loaded_specs['choria-mcorpc-support'].version
      stub_const('MCollective::Util::FileTransfer::GEM_REQUIREMENT', Gem::Requirement.new("> #{installed}"))

      expect { described_class.new({}, logger: log) }
        .to raise_error(RuntimeError, "The choria-mcorpc-support gem is #{installed}, and this library needs choria-mcorpc-support > #{installed}")
    end

    it 'refuses a choria-mcorpc-support that is not loaded through RubyGems, since its version is unknown' do
      allow(Gem).to receive(:loaded_specs).and_return({})

      expect { described_class.new({}, logger: log) }.to raise_error(RuntimeError, /not loaded through RubyGems/)
    end
  end

  describe 'the rpc timeout' do
    it 'is 300 seconds by default, which is longer than the DDL timeout' do
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
      source = local_file('source.bin', 'x')

      described_class.new({}, logger: log).upload(source, '/opt/app/source.bin', [node1])

      expect(rpc.calls.map(&:last).uniq).to eq([300])
    end
  end

  describe 'the connection it builds' do
    it 'gets the caller\'s options and mutex' do
      caller_options = { config: '/etc/choria/client.conf' }
      mutex = Mutex.new
      expect(MCollective::Util::FileTransfer::Connection).to receive(:new).with(caller_options, mutex: mutex).and_call_original

      described_class.new(caller_options, mutex: mutex, logger: log)
    end
  end

  describe 'the first log lines' do
    it 'are the data per message at debug, from when the client was built, then the upload with its node count at info' do
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
      source = local_file('source.bin', 'x')

      client.upload(source, '/opt/app/source.bin', [node1])

      expect(log.debugs.first).to eq('Each message contains up to 16384 bytes of data')
      expect(log.infos).to eq(["Upload of #{source} to /opt/app/source.bin on 1 node"])
    end

    it 'are the data per message at debug, from when the client was built, then the download with its node count at info' do
      stub_file_stats
      stub_get

      client.download('/var/log/app.log', destination_dirs)

      expect(log.debugs.first).to eq('Each message contains up to 16384 bytes of data')
      expect(log.infos).to eq(['Download of /var/log/app.log from 2 nodes'])
    end
  end

  context 'with the default message data size' do
    let(:client) { described_class.new({}, logger: log, rpc_timeout: rpc_timeout) }

    # The fake sizes a request at twice its content, more than a real one
    # at half the limit, so here a request is the size of its content and an envelope.
    def wire_size(args)
      decoded(args).bytesize + 300
    end

    it 'sends 512 KiB of file content per request, half the broker limit' do
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
      source = local_file('source.bin', SecureRandom.random_bytes(600 * 1024))

      outcomes = client.upload(source, '/opt/app/source.bin', [node1])

      expect(put_calls.map { |call| decoded(call).bytesize }).to eq([512 * 1024, 88 * 1024])
      expect(outcomes[node1]).to be_success
      expect(log.debugs.count('Each message contains up to 524288 bytes of data')).to eq(1)
    end

    it 'asks for 512 KiB per get reply and per listing' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' } })

      outcomes = client.download('/srv/data', destination_dirs.slice(node1))

      expect(outcomes[node1]).to be_success
      expect(rpc.calls.find { |call| call.first == :list }[1]).to include(max_bytes: 512 * 1024)
      expect(get_calls.map { |call| call[:max_bytes] }).to eq([512 * 1024])
    end
  end

  context 'with a message data size' do
    it 'sends that many kibibytes per request whatever the broker limit' do
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
      source = local_file('source.bin', SecureRandom.random_bytes(40 * 1024))

      outcomes = client.upload(source, '/opt/app/source.bin', [node1])

      expect(put_calls.map { |call| decoded(call).bytesize }).to eq([16 * 1024, 16 * 1024, 8 * 1024])
      expect(outcomes[node1]).to be_success
      expect(log.debugs.count("Each message contains up to #{16 * 1024} bytes of data")).to eq(1)
    end
  end
end
