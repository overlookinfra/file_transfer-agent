# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Rpc do
  include_context 'with a file transfer client'

  let(:agent_rpc) { described_class.new(connection, log, 30) }

  def stat_call(identities = nodes, **settings)
    agent_rpc.call(identities, 'file_transfer.stat /x', **settings) { |rpc_client| rpc_client.stat(path: '/x') }
  end

  it 'indexes the replies by identity' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    response = stat_call

    expect(response.responded).to eq(node1 => { exists: true }, node2 => { exists: true })
    expect(response.errors).to be_empty
  end

  it 'reports a node without a reply as no_response' do
    stub_stat { |_args, names| results_for(names - [node2], { exists: true }) }

    response = stat_call

    expect(response.responded.keys).to eq([node1])
    expect(response.errors[node2].kind).to eq(:no_response)
    expect(response.errors[node2].message).to include(node2, 'file_transfer.stat /x')
  end

  it 'reports a status code above 1 as an rpc_error carrying the message and the code' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 4, statusmsg: 'The path input must be an absolute path') }

    response = stat_call

    expect(response.responded).to be_empty
    expect(response.errors.values.map(&:kind).uniq).to eq([:rpc_error])
    expect(response.errors[node1].message).to include('The path input must be an absolute path', 'code 4')
  end

  it 'reports status code 1 as a transfer failure carrying the agent message' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 1, statusmsg: 'Permission denied') }

    response = stat_call

    expect(response.responded).to be_empty
    expect(response.errors[node1].kind).to eq(:transfer_failed)
    expect(response.errors[node1].message).to eq("file_transfer.stat /x on #{node1} failed: Permission denied")
  end

  it 'reports a reply without a data hash as a transfer failure' do
    stub_stat { |_args, names| names.map { |name| rpc_result(name, nil) } }

    response = stat_call

    expect(response.responded).to be_empty
    expect(response.errors[node2].kind).to eq(:transfer_failed)
    expect(response.errors[node2].message).to include('answered without usable data')
  end

  it 'fails every node when the call raises' do
    stub_stat { |_args, _names| raise 'broker down' }

    response = stat_call

    expect(response.errors.values.map(&:kind).uniq).to eq([:rpc_failed])
    expect(response.errors[node1].message).to include('broker down')
    expect(log.warnings).to include(a_string_including('RPC call failed', 'broker down'))
  end

  it 'discards a reply from a node it did not address and warns' do
    stub_stat { |_args, names| results_for(names + ['other.example.com'], { exists: true }) }

    response = stat_call

    expect(response.responded.keys).to eq(nodes)
    expect(log.warnings).to include(a_string_including('unexpected sender', 'other.example.com'))
  end

  it 'keeps the first of two replies from one node' do
    stub_stat { |_args, _names| [rpc_result(node1, { exists: true }), rpc_result(node1, { exists: false })] }

    response = stat_call([node1])

    expect(response.responded).to eq(node1 => { exists: true })
    expect(log.warnings).to include(a_string_including('duplicate', node1))
  end

  it 'answers an empty response without a call when there are no identities' do
    response = stat_call([])

    expect(response.responded).to be_empty
    expect(response.errors).to be_empty
    expect(connection.calls).to be_empty
  end

  it 'waits the rpc timeout for replies and allows it for publishing too' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    stat_call

    expect(connection.calls).to eq([{ agent: 'file_transfer', identities: nodes, timeout: 30, publish_timeout: 30 }])
  end

  it 'waits a given timeout for replies while still allowing the rpc timeout for publishing' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    stat_call(timeout: 7)

    expect(connection.calls.first).to include(timeout: 7, publish_timeout: 30)
  end

  it 'waits the DDL timeout for a call that digests a file on the node, or the rpc timeout when that is longer' do
    expect(agent_rpc.digest_timeout).to eq(120)
    expect(described_class.new(connection, log, 300).digest_timeout).to eq(300)
  end

  it 'sends a call in batches of the given size without a pause between them' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    response = stat_call(batch_size: 1)

    expect(rpc.batch_size).to eq(1)
    expect(rpc.batch_sleep_time).to eq(0)
    expect(response.responded.keys).to eq(nodes)
  end

  it 'leaves a call without a batch size unbatched' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    stat_call

    expect(rpc.batch_size).to be_nil
  end

  it 'answers the largest message a guarded call published and 0 for an unguarded one' do
    stub_stat do |_args, names|
      wrapper.publish('subject', 'x' * 500)
      results_for(names, { exists: true })
    end

    expect(stat_call(guard: 1_000).wire_bytes).to eq(500)
    expect(stat_call.wire_bytes).to eq(0)
  end

  it 'fails every node with payload_too_large when the guard refuses the message, naming the chunk size as the remedy' do
    stub_stat do |_args, names|
      wrapper.publish('subject', 'x' * 1_500)
      results_for(names, { exists: true })
    end

    response = stat_call(guard: 1_000)

    expect(wrapper.published).to be_empty
    expect(response.errors.values.map(&:kind).uniq).to eq([:payload_too_large])
    expect(response.errors[node1].message).to include("file_transfer.stat /x on #{node1} was not sent", '1500 byte message', 'Lower the chunk size')
  end
end
