# frozen_string_literal: true

require 'spec_helper'
require 'mcollective/connector/nats'

RSpec.describe MCollective::Util::FileTransfer::Connection do
  let(:rpc_client) { instance_double(MCollective::RPC::Client, 'progress=': nil, 'timeout=': nil, discover: nil) }
  let(:options) { { timeout: 5, collective: 'mcollective', filter: {} } }
  let(:connection) { described_class.new(options) }

  it 'builds a client for the agent that addresses the identities directly, with the wait as the request TTL, and yields it' do
    expect(MCollective::RPC::Client).to receive(:new)
      .with('file_transfer', options: hash_including(verbose: false, publish_timeout: 30, ttl: 12, collective: 'mcollective'))
      .and_return(rpc_client)
    expect(rpc_client).to receive(:discover).with(nodes: ['node1.example.com'])
    expect(rpc_client).to receive(:progress=).with(false)
    yielded = nil

    answer = connection.with_client('file_transfer', ['node1.example.com'], timeout: 12, publish_timeout: 30) do |client|
      yielded = client
      :done
    end

    expect(yielded).to be(rpc_client)
    expect(answer).to eq(:done)
  end

  # The gem's client replaces a timeout of exactly 5 in its options with
  # the DDL timeout plus the discovery timeout while it is built, so the
  # timeout goes through the accessor afterwards, where it is taken as given.
  it 'sets the timeout on the client after building it' do
    expect(MCollective::RPC::Client).to receive(:new).ordered.and_return(rpc_client)
    expect(rpc_client).to receive(:timeout=).with(5).ordered

    connection.with_client('file_transfer', ['node1.example.com'], timeout: 5, publish_timeout: 30) { nil }
  end

  # A real client without its constructor, which would connect to a broker,
  # in the state the gem leaves it when threading is turned on.
  context 'when the gem built a client that publishes threaded' do
    let(:threaded_client) do
      client = MCollective::RPC::Client.allocate
      client.instance_variable_set(:@threaded, true)
      client.instance_variable_set(:@discovery_timeout, 2)
      allow(client).to receive(:discover)
      client
    end

    before { allow(MCollective::RPC::Client).to receive(:new).and_return(threaded_client) }

    it 'hands the caller a client whose requests publish unthreaded' do
      request_options = connection.with_client('file_transfer', ['node1.example.com'], timeout: 12, publish_timeout: 30, &:options)

      expect(request_options).to include(threaded: false, timeout: 12)
    end
  end

  it 'drops a target limit and a batch size from the options, since every call addresses the identities it is given' do
    limited = described_class.new(options.merge(mcollective_limit_targets: 1, batch_size: '2'))
    expect(MCollective::RPC::Client).to receive(:new)
      .with('file_transfer', options: hash_including(mcollective_limit_targets: false, batch_size: 0)).and_return(rpc_client)

    limited.with_client('file_transfer', ['node1.example.com'], timeout: 12, publish_timeout: 30) { nil }
  end

  it 'leaves the options it was built with untouched' do
    allow(MCollective::RPC::Client).to receive(:new).and_return(rpc_client)

    connection.with_client('file_transfer', ['node1.example.com'], timeout: 12, publish_timeout: 30) { nil }

    expect(options).to eq(timeout: 5, collective: 'mcollective', filter: {})
  end

  describe '#guard' do
    let(:wrapper) { FakeNatsWrapper.new }

    before do
      allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(instance_double(MCollective::Connector::Nats, connection: wrapper))
    end

    it 'refuses a message over the limit before it is sent, naming both sizes' do
      expect { connection.guard(100) { wrapper.publish('subject', 'x' * 130) } }
        .to raise_error(MCollective::Util::FileTransfer::PayloadTooLarge, "A 130 byte message exceeds the broker's 100 byte payload limit")
      expect(wrapper.published).to be_empty
    end

    it 'sends a message at the limit and answers what the block answers' do
      answer = connection.guard(100) do
        wrapper.publish('subject', 'x' * 100)
        :done
      end

      expect(wrapper.published).to eq([100])
      expect(answer).to eq(:done)
    end

    it 'lifts the limit after the block, also when the block raised' do
      connection.guard(100) { nil }
      wrapper.publish('subject', 'x' * 130)
      expect { connection.guard(100) { raise 'broker down' } }.to raise_error('broker down')
      wrapper.publish('subject', 'x' * 140)

      expect(wrapper.published).to eq([130, 140])
    end

    it 'changes the wrapper class on the first call only' do
      connection.guard(100) { nil }
      guarded = wrapper.class.ancestors
      connection.guard(100) { nil }

      expect(wrapper.class.ancestors).to eq(guarded)
    end
  end

  describe 'the base64 check it puts in front of the gem\'s decode' do
    before { connection }

    it 'decodes a payload the gem accepts, with the line breaks the gem\'s own encoder adds' do
      expect(MCollective::SSL.base64_decode("aGVs\nbG8=\n")).to eq('hello')
    end

    it 'refuses a payload with a character outside base64, as the gem does' do
      expect { MCollective::SSL.base64_decode('aGVs*bG8=') }.to raise_error(ArgumentError, 'invalid base64')
    end

    it 'refuses an empty payload, as the gem does' do
      expect { MCollective::SSL.base64_decode('') }.to raise_error(ArgumentError, 'invalid base64')
    end

    it 'changes the SSL module on the first connection only' do
      ancestors = MCollective::SSL.singleton_class.ancestors
      described_class.new(options)

      expect(MCollective::SSL.singleton_class.ancestors).to eq(ancestors)
    end
  end

  it 'runs every call under the mutex it is given, so a caller can share its own lock' do
    mutex = Mutex.new
    shared = described_class.new(options, mutex: mutex)
    allow(MCollective::RPC::Client).to receive(:new).and_return(rpc_client)

    held = shared.with_client('file_transfer', ['node1.example.com'], timeout: 5, publish_timeout: 30) { mutex.owned? }

    expect(held).to be(true)
    expect(mutex.owned?).to be(false)
  end
end
