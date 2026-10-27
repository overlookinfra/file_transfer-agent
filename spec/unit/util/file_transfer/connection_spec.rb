# frozen_string_literal: true

require 'spec_helper'
require 'mcollective/connector/nats'

RSpec.describe MCollective::Util::FileTransfer::Connection do
  let(:rpc) { FakeRpcClient.new }
  let(:built) { [] }
  let(:options) { { timeout: 5, collective: 'mcollective', filter: {} } }
  let(:connection) { described_class.new(options, mutex: Mutex.new) }
  let(:wrapper) { FakeNatsWrapper.new }

  # Every client the connection builds is the fake one, with the agent and
  # options it was built with recorded in built. Every call prepends the
  # publish guard onto the class of the NATS wrapper that the connector
  # plugin contains, the fake one here.
  before do
    allow(MCollective::RPC::Client).to receive(:new) do |agent, options:|
      built << [agent, options]
      rpc
    end
    allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(instance_double(MCollective::Connector::Nats, connection: wrapper))
  end

  it 'builds a client for the agent that addresses the identities directly, with the wait as the publish timeout and the request TTL, and yields it' do
    yielded = nil

    result = connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) do |client|
      yielded = client
      :done
    end

    expect(built).to match([['file_transfer', hash_including(verbose: false, publish_timeout: 12, ttl: 12, collective: 'mcollective')]])
    expect(rpc.identities).to eq(['node1.example.com'])
    expect(rpc.progress).to be(false)
    expect(yielded).to be(rpc)
    expect(result).to eq(:done)
  end

  # The gem's client replaces a timeout of exactly 5 in its options with
  # the DDL timeout plus the discovery timeout while it is built, so the
  # timeout goes through the accessor afterwards, where it is taken as
  # given. The fake reads no options, so only the accessor can set its
  # timeout.
  it 'sets the timeout on the client after building it' do
    connection.with_client('file_transfer', ['node1.example.com'], timeout: 5) { nil }

    expect(rpc.timeout).to eq(5)
  end

  it 'builds every client unthreaded, whatever the options say, so a publish guard refusal reaches the caller' do
    threaded = described_class.new(options.merge(threaded: true), mutex: Mutex.new)

    threaded.with_client('file_transfer', ['node1.example.com'], timeout: 12) { nil }

    expect(built.last[1]).to include(threaded: false)
  end

  it 'drops a target limit and a batch size from the options, since every call addresses the identities it is given' do
    limited = described_class.new(options.merge(mcollective_limit_targets: 1, batch_size: '2'), mutex: Mutex.new)

    limited.with_client('file_transfer', ['node1.example.com'], timeout: 12) { nil }

    expect(built.last[1]).to include(mcollective_limit_targets: false, batch_size: 0)
  end

  it 'leaves the options it was built with untouched' do
    connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) { nil }

    expect(options).to eq(timeout: 5, collective: 'mcollective', filter: {})
  end

  it 'sets a batch size and no pause between the batches on the client for a call with a batch size, and neither for a call without' do
    connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) { nil }

    expect([rpc.batch_size, rpc.batch_sleep_time]).to eq([nil, nil])

    connection.with_client('file_transfer', ['node1.example.com'], timeout: 12, batch_size: 2) { nil }

    expect([rpc.batch_size, rpc.batch_sleep_time]).to eq([2, 0])
  end

  describe 'the publish guard' do
    let(:limit) { MCollective::Util::FileTransfer::Connection::MAX_PAYLOAD }

    it 'refuses a message over the broker limit published inside the block before it is sent, naming both sizes' do
      expect { connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) { wrapper.publish('subject', 'x' * (limit + 1)) } }
        .to raise_error(MCollective::Util::FileTransfer::PayloadTooLarge, "A #{limit + 1} byte message exceeds the broker's #{limit} byte payload limit")
      expect(wrapper.published).to be_empty
    end

    it 'sends a message at the broker limit and returns what the block returns' do
      result = connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) do
        wrapper.publish('subject', 'x' * limit)
        :done
      end

      expect(wrapper.published).to eq([limit])
      expect(result).to eq(:done)
    end

    it 'still refuses a message over the broker limit published after the block' do
      connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) { nil }

      expect { wrapper.publish('subject', 'x' * (limit + 1)) }.to raise_error(MCollective::Util::FileTransfer::PayloadTooLarge)
      expect(wrapper.published).to be_empty
    end

    it 'changes the wrapper class on the first call only' do
      connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) { nil }
      guarded = wrapper.class.ancestors
      connection.with_client('file_transfer', ['node1.example.com'], timeout: 12) { nil }

      expect(wrapper.class.ancestors).to eq(guarded)
    end
  end

  it 'runs every call under the mutex it is given, so a caller can share its own lock' do
    mutex = Mutex.new
    shared = described_class.new(options, mutex: mutex)

    held = shared.with_client('file_transfer', ['node1.example.com'], timeout: 5) { mutex.owned? }

    expect(held).to be(true)
    expect(mutex.owned?).to be(false)
  end
end
