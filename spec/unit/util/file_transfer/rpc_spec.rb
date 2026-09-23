# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Rpc do
  include_context 'with a file transfer client'

  def stat_call(identities = nodes, timeout: nil)
    client.rpc.agent_call(identities, 'file_transfer.stat /x', timeout: timeout) { |rpc_client| rpc_client.stat(path: '/x') }
  end

  it 'indexes the replies by identity with their status codes' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    response = stat_call

    expect(response[:responded]).to eq(node1 => { exists: true }, node2 => { exists: true })
    expect(response[:errors]).to be_empty
    expect(response[:rpc_failed]).to be(false)
    expect(response[:statuscodes]).to eq(node1 => 0, node2 => 0)
    expect(response[:statusmsgs]).to eq(node1 => 'OK', node2 => 'OK')
  end

  it 'reports a node without a reply as no_response' do
    stub_stat { |_args, names| results_for(names - [node2], { exists: true }) }

    response = stat_call

    expect(response[:responded].keys).to eq([node1])
    expect(response[:errors][node2].kind).to eq(:no_response)
    expect(response[:errors][node2].message).to include(node2, 'file_transfer.stat /x')
  end

  it 'reports a status code above 1 as an rpc_error carrying the message and the code' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 4, statusmsg: 'The path input must be an absolute path') }

    response = stat_call

    expect(response[:responded]).to be_empty
    expect(response[:errors].values.map(&:kind).uniq).to eq([:rpc_error])
    expect(response[:errors][node1].message).to include('The path input must be an absolute path', 'code 4')
  end

  it 'reports status code 1 as a transfer failure carrying the agent message' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 1, statusmsg: 'Permission denied') }

    response = stat_call

    expect(response[:responded]).to be_empty
    expect(response[:errors][node1].kind).to eq(:transfer_failed)
    expect(response[:errors][node1].message).to eq("file_transfer.stat /x on #{node1} failed: Permission denied")
  end

  it 'reports a reply without a data hash as a transfer failure' do
    stub_stat { |_args, names| names.map { |name| rpc_result(name, nil) } }

    response = stat_call

    expect(response[:responded]).to be_empty
    expect(response[:errors][node2].kind).to eq(:transfer_failed)
    expect(response[:errors][node2].message).to include('answered without usable data')
  end

  it 'fails every node when the call raises' do
    stub_stat { |_args, _names| raise 'broker down' }

    response = stat_call

    expect(response[:rpc_failed]).to be(true)
    expect(response[:errors].values.map(&:kind).uniq).to eq([:rpc_failed])
    expect(response[:errors][node1].message).to include('broker down')
    expect(log.warnings).to include(a_string_including('RPC call failed', 'broker down'))
  end

  it 'discards a reply from a node it did not address and warns' do
    stub_stat { |_args, names| results_for(names + ['other.example.com'], { exists: true }) }

    response = stat_call

    expect(response[:responded].keys).to eq(nodes)
    expect(log.warnings).to include(a_string_including('unexpected sender', 'other.example.com'))
  end

  it 'keeps the first of two replies from one node' do
    stub_stat { |_args, _names| [rpc_result(node1, { exists: true }), rpc_result(node1, { exists: false })] }

    response = stat_call([node1])

    expect(response[:responded]).to eq(node1 => { exists: true })
    expect(log.warnings).to include(a_string_including('duplicate', node1))
  end

  it 'answers an empty response without a call when there are no identities' do
    response = stat_call([])

    expect(response).to eq(responded: {}, errors: {}, rpc_failed: false, statuscodes: {}, statusmsgs: {})
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

  it 'sends a call in batches of the given size without a pause between them' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    response = client.rpc.agent_call(nodes, 'file_transfer.stat /x', batch_size: 1) { |rpc_client| rpc_client.stat(path: '/x') }

    expect(rpc.batch_size).to eq(1)
    expect(rpc.batch_sleep_time).to eq(0)
    expect(response[:responded].keys).to eq(nodes)
  end

  it 'leaves a call without a batch size unbatched' do
    stub_stat { |_args, names| results_for(names, { exists: true }) }

    stat_call

    expect(rpc.batch_size).to be_nil
  end
end
