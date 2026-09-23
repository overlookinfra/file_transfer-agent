# frozen_string_literal: true

require 'spec_helper'
require 'mcollective/connector/nats'

RSpec.describe MCollective::Util::FileTransfer::Connection do
  let(:rpc_client) { instance_double(MCollective::RPC::Client, 'progress=': nil, discover: nil) }
  let(:options) { { timeout: 5, collective: 'mcollective', filter: {} } }
  let(:connection) { described_class.new(options) }

  it 'builds a client for the agent that addresses the identities directly and yields it' do
    expect(MCollective::RPC::Client).to receive(:new)
      .with('file_transfer', options: hash_including(timeout: 12, verbose: false, publish_timeout: 30, threaded: false, collective: 'mcollective'))
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
end
