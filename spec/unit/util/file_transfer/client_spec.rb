# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Client do
  include_context 'with a download client'

  describe 'the timeout and the sizes it is given' do
    [0, -1, 1.5, '16'].each do |value|
      it "refuses #{value.inspect} as the rpc timeout" do
        expect { described_class.new({}, logger: log, rpc_timeout: value) }
          .to raise_error(ArgumentError, "rpc_timeout must be an integer above zero, not #{value.inspect}")
      end
    end

    [:message_data_size, :upload_batch_size].each do |size|
      it "refuses 0 as the #{size}" do
        expect { described_class.new({}, logger: log, size => 0) }.to raise_error(ArgumentError, "#{size} must be an integer above zero, not 0")
      end
    end
  end

  describe 'the rpc timeout' do
    it 'is 300 seconds without one, for replies and for publishing alike, which is longer than the DDL timeout' do
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
      source = local_file('source.bin', 'x')

      described_class.new({}, logger: log).upload(source, '/opt/app/source.bin', [node1])

      expect(connection.calls.map { |call| [call[:timeout], call[:publish_timeout]] }.uniq).to eq([[300, 300]])
    end
  end

  describe 'the first debug line' do
    it 'names the upload and counts its nodes' do
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
      source = local_file('source.bin', 'x')

      client.upload(source, '/opt/app/source.bin', [node1])

      expect(log.debugs.first).to eq("Upload of #{source} to /opt/app/source.bin on 1 node")
    end

    it 'names the download and counts its nodes' do
      stub_file_stats
      stub_get

      client.download('/var/log/app.log', destination_dirs)

      expect(log.debugs.first).to eq('Download of /var/log/app.log from 2 nodes')
    end
  end

  context 'without a message data size' do
    let(:message_data_size) { nil }
    let(:max_payload) { 4 * 1024 * 1024 }

    # The fake weighs a request at twice its content, more than a real one
    # at half the limit, so here a request weighs its content and an envelope.
    def wire_size(args)
      decoded(args).bytesize + 300
    end

    it 'sends half the broker limit of file content per request' do
      stub_stat { |_args, names| results_for(names, { exists: false }) }
      stub_put
      source = local_file('source.bin', SecureRandom.random_bytes((2 * 1024 * 1024) + 100))

      outcomes = client.upload(source, '/opt/app/source.bin', [node1])

      expect(put_calls.map { |call| decoded(call).bytesize }).to eq([2 * 1024 * 1024, 100])
      expect(outcomes[node1]).to be_success
      expect(log.debugs.count("Each message carries up to #{2 * 1024 * 1024} bytes of data")).to eq(1)
    end

    it 'asks for half the broker limit per get reply and per listing' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' } })

      outcomes = client.download('/srv/data', destination_dirs.slice(node1))

      expect(outcomes[node1]).to be_success
      expect(rpc.calls.find { |call| call.first == :list }[1]).to include(max_bytes: 2 * 1024 * 1024)
      expect(get_calls.map { |call| call[:max_bytes] }).to eq([2 * 1024 * 1024])
    end

    context 'when the broker limit cannot be read' do
      let(:wrapper) { FakeNatsWrapper.new(nil) }

      it 'sends 512 KiB per request under the assumed limit' do
        stub_stat { |_args, names| results_for(names, { exists: false }) }
        stub_put
        source = local_file('source.bin', SecureRandom.random_bytes(600 * 1024))

        outcomes = client.upload(source, '/opt/app/source.bin', [node1])

        expect(log.once_ids).to eq(['file_transfer_max_payload_unknown'])
        expect(put_calls.map { |call| decoded(call).bytesize }).to eq([512 * 1024, 88 * 1024])
        expect(outcomes[node1]).to be_success
      end
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
      expect(log.debugs.count("Each message carries up to #{16 * 1024} bytes of data")).to eq(1)
    end
  end
end
