# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'mcollective/connector/nats'
require 'mcollective/security/choria'

RSpec.describe MCollective::Util::FileTransfer::Connection do
  let(:rpc_client) { instance_double(MCollective::RPC::Client, 'progress=': nil, 'timeout=': nil, discover: nil) }
  let(:options) { { timeout: 5, collective: 'mcollective', filter: {} } }
  let(:connection) { described_class.new(options) }

  it 'builds a client for the agent that addresses the identities directly and yields it' do
    expect(MCollective::RPC::Client).to receive(:new)
      .with('file_transfer', options: hash_including(verbose: false, publish_timeout: 30, threaded: false, collective: 'mcollective'))
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

  it 'leaves publishing to the client library defaults when no publish timeout is given' do
    expect(MCollective::RPC::Client).to receive(:new)
      .with('rpcutil', options: hash_excluding(:publish_timeout, :threaded))
      .and_return(rpc_client)

    connection.with_client('rpcutil', ['node1.example.com'], timeout: 5, publish_timeout: nil) { nil }
  end

  it 'leaves the options it was built with untouched' do
    allow(MCollective::RPC::Client).to receive(:new).and_return(rpc_client)

    connection.with_client('file_transfer', ['node1.example.com'], timeout: 12, publish_timeout: 30) { nil }

    expect(options).to eq(timeout: 5, collective: 'mcollective', filter: {})
  end

  it 'answers the connector plugin connection as the NATS wrapper' do
    wrapper = Object.new
    allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(instance_double(MCollective::Connector::Nats, connection: wrapper))

    expect(connection.nats_wrapper).to be(wrapper)
  end

  it 'raises when no connector plugin is loaded' do
    allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_raise('No plugin connector_plugin defined')

    expect { connection.nats_wrapper }.to raise_error(RuntimeError, 'No plugin connector_plugin defined')
  end

  it 'answers nil for a connector without a connection' do
    allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(Object.new)

    expect(connection.nats_wrapper).to be_nil
  end

  it 'reads the payload limit off the wrapper client\'s server info' do
    wrapper = FakeNatsWrapper.new(4_194_304)
    allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(instance_double(MCollective::Connector::Nats, connection: wrapper))

    expect(connection.max_payload).to eq(4_194_304)
  end

  it 'raises for the payload limit when the connector has no wrapper' do
    allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(Object.new)

    expect { connection.max_payload }.to raise_error(NoMethodError)
  end

  it 'runs every call under the mutex it is given, so a caller can share its own lock' do
    mutex = Mutex.new
    shared = described_class.new(options, mutex: mutex)
    allow(MCollective::RPC::Client).to receive(:new).and_return(rpc_client)

    held = shared.with_client('file_transfer', ['node1.example.com'], timeout: 5, publish_timeout: nil) { mutex.owned? }

    expect(held).to be(true)
    expect(mutex.owned?).to be(false)
  end

  # The request is built with the gem's own Message and the plugins it
  # calls, so the sequence and the transport JSON are checked against
  # them rather than against a model of them.
  describe '#request_bytes' do
    let(:args) { { session: 's' * 36, name: 'app.tar', offset: 0, data: ['x' * 300].pack('m0') } }
    let(:request) { { agent: 'file_transfer', action: 'put', caller: 'choria=controller.mcollective', data: args } }
    let(:client_options) { { timeout: 5, collective: 'mcollective', filter: MCollective::Util.empty_filter, ttl: 60 } }
    let(:secure) { { 'protocol' => 'choria:secure:request:1', 'message' => 'x' * 900, 'signature' => 'y' * 344, 'pubcert' => 'z' * 1_200 }.to_json }
    let(:headers) { { 'mc_sender' => 'controller.example.com', 'reply-to' => 'mcollective.reply.abc.1.2' } }
    let(:security) { instance_double(MCollective::Security::Choria, encoderequest: secure) }
    let(:connector) { instance_double(MCollective::Connector::Nats) }
    let(:signed) { [] }
    let(:targeted) { [] }

    before do
      allow(MCollective::Config.instance).to receive_messages(direct_addressing: true, identity: 'controller.example.com', ttl: 60)
      allow(MCollective::PluginManager).to receive(:[]).with('security_plugin').and_return(security)
      allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(connector)
      allow(MCollective::RPC::Client).to receive(:new).with('file_transfer', options: hash_including(verbose: false)).and_return(rpc_client)
      allow(rpc_client).to receive_messages(options: client_options, new_request: request)
      allow(security).to receive(:encoderequest) do |*call|
        signed << call
        secure
      end
      allow(connector).to receive(:target_for) do |message, identity|
        targeted << [message, identity]
        { name: "mcollective.node.#{identity}", headers: headers }
      end
    end

    it 'measures the signed request and the transport message the connector would publish for it' do
      measured = connection.request_bytes('file_transfer', 'put', args, 'node1.example.com')

      expect(measured.signed_bytes).to eq(secure.bytesize)
      expect(measured.wire_bytes).to eq({ 'protocol' => 'choria:transport:1', 'data' => [secure].pack('m'), 'headers' => headers }.to_json.bytesize)
    end

    it 'builds the request as the client does and signs it as a direct request for the identity' do
      expect(rpc_client).to receive(:new_request).with('put', args).and_return(request)

      connection.request_bytes('file_transfer', 'put', args, 'node1.example.com')

      sender, message, requestid, filter, agent, collective, ttl = signed.first
      expect(sender).to eq('controller.example.com')
      expect(message).to eq(request)
      expect(requestid).to match(/\A[0-9a-f]{32}\z/)
      expect(filter['agent']).to eq(['file_transfer'])
      expect([agent, collective, ttl]).to eq(['file_transfer', 'mcollective', 60])
      message, identity = targeted.first
      expect(message.type).to eq(:direct_request)
      expect(message.discovered_hosts).to eq(['node1.example.com'])
      expect(identity).to eq('node1.example.com')
    end

    it 'runs under the mutex and sends nothing' do
      expect(connector).not_to receive(:publish)
      mutex = Mutex.new
      shared = described_class.new(options, mutex: mutex)
      allow(rpc_client).to receive(:new_request) { mutex.owned? ? request : raise('built outside the lock') }

      expect { shared.request_bytes('file_transfer', 'put', args, 'node1.example.com') }.not_to raise_error
    end
  end
end
