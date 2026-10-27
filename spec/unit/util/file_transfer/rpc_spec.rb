# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Rpc do
  include_context 'with a file transfer client'

  let(:connection) { MCollective::Util::FileTransfer::Connection.new({}, mutex: Mutex.new) }
  let(:agent_rpc) { described_class.new(connection, log, 30, message_data_bytes: 16_384, upload_batch_size: 256) }

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
    expect(response.errors[node2].error_kind).to eq(:no_response)
    expect(response.errors[node2].error_message).to include(node2, 'file_transfer.stat /x')
  end

  it 'reports a status code above 1 as an rpc_error containing the message and the code' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 4, statusmsg: 'The path input must be an absolute path') }

    response = stat_call

    expect(response.responded).to be_empty
    expect(response.errors.values.map(&:error_kind).uniq).to eq([:rpc_error])
    expect(response.errors[node1].error_message).to include('The path input must be an absolute path', 'code 4')
  end

  it 'reports status code 1 as a transfer failure containing the agent message' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 1, statusmsg: 'Permission denied') }

    response = stat_call

    expect(response.responded).to be_empty
    expect(response.errors[node1].error_kind).to eq(:transfer_failed)
    expect(response.errors[node1].error_message).to eq("The file_transfer.stat /x call on #{node1} failed: Permission denied")
  end

  it 'keeps the data of each reply with status code 1 and of no other reply' do
    stub_stat do |_args, names|
      names.map { |name| name == node1 ? rpc_result(name, { sha256: 'f' * 64 }, statuscode: 1, statusmsg: 'Checksum mismatch') : rpc_result(name, { exists: true }) }
    end

    response = stat_call

    expect(response.aborted).to eq(node1 => { sha256: 'f' * 64 })
    expect(response.responded).to eq(node2 => { exists: true })
  end

  # The gem raises on a reply whose data is nil while it builds the result,
  # before the library sees it, so an array stands in for data that is not
  # a hash.
  it 'reports a reply without a data hash as a transfer failure' do
    stub_stat { |_args, names| names.map { |name| rpc_result(name, []) } }

    response = stat_call

    expect(response.responded).to be_empty
    expect(response.errors[node2].error_kind).to eq(:transfer_failed)
    expect(response.errors[node2].error_message).to include('answered without usable data')
  end

  it 'reports a reply without a status code as a transfer failure of that node only' do
    stub_stat do |_args, names|
      names.map { |name| rpc_result(name, { exists: true }, statuscode: name == node2 ? nil : 0) }
    end

    response = stat_call

    expect(response.responded).to eq(node1 => { exists: true })
    expect(response.errors.keys).to eq([node2])
    expect(response.errors[node2].error_kind).to eq(:transfer_failed)
    expect(response.errors[node2].error_message).to eq("The file_transfer.stat /x call on #{node2} answered without a status code")
  end

  it 'fails every node when the call raises' do
    stub_stat { |_args, _names| raise 'broker down' }

    response = stat_call

    expect(response.errors.values.map(&:error_kind).uniq).to eq([:rpc_failed])
    expect(response.errors[node1].error_message).to include('broker down')
    expect(log.errors).to include(a_string_including('RPC call failed', 'broker down'))
  end

  it 'discards a reply from a node it did not address and warns' do
    stub_stat { |_args, names| results_for(names + ['other.example.com'], { exists: true }) }

    response = stat_call

    expect(response.responded.keys).to eq(nodes)
    expect(log.warnings).to include(a_string_including('unexpected sender', 'other.example.com'))
  end

  it 'keeps the first of 2 replies from one node' do
    stub_stat { |_args, _names| [rpc_result(node1, { exists: true }), rpc_result(node1, { exists: false })] }

    response = stat_call([node1])

    expect(response.responded).to eq(node1 => { exists: true })
    expect(log.warnings).to include(a_string_including("another file_transfer.stat /x response from #{node1}", 'only its first counts'))
  end

  it 'returns an empty response without a call when there are no identities' do
    response = stat_call([])

    expect(response.responded).to be_empty
    expect(response.errors).to be_empty
    expect(rpc.calls).to be_empty
  end

  it 'waits the DDL timeout for replies and for publishing when the rpc timeout is below it, and names both in a silence' do
    stub_stat { |_args, names| results_for(names - [node2], { exists: true }) }

    response = stat_call

    expect(rpc.calls.map { |call| [call.first, call[2], call.last] }).to eq([[:stat, nodes, 120]])
    expect(response.errors[node2].error_kind).to eq(:no_response)
    expect(response.errors[node2].error_message).to eq(
      "No response from #{node2} for file_transfer.stat /x within 120 seconds. If the node is up, its server may have stopped " \
      'the agent at the DDL timeout of 120 seconds.'
    )
  end

  context 'with an rpc timeout above the DDL timeout' do
    let(:agent_rpc) { described_class.new(connection, log, 300, message_data_bytes: 16_384, upload_batch_size: 256) }

    it 'waits the rpc timeout for replies and for publishing, and names both timeouts in a silence' do
      stub_stat { |_args, names| results_for(names - [node2], { exists: true }) }

      response = stat_call

      expect(rpc.calls.first.last).to eq(300)
      expect(response.errors[node2].error_message).to include('within 300 seconds', 'the DDL timeout of 120 seconds')
    end
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

  it 'keeps every message under the broker limit' do
    limit = MCollective::Util::FileTransfer::Connection::MAX_PAYLOAD
    stub_stat do |_args, names|
      wrapper.publish('subject', 'x' * limit)
      results_for(names, { exists: true })
    end

    stat_call

    expect { wrapper.publish('subject', 'x' * (limit + 1)) }.to raise_error(MCollective::Util::FileTransfer::PayloadTooLarge)
    expect(wrapper.published).to eq([limit])
  end

  it 'fails every node with payload_too_large when the guard refuses a message over the broker limit, naming the message data size as the remedy' do
    stub_stat do |_args, names|
      wrapper.publish('subject', 'x' * (MCollective::Util::FileTransfer::Connection::MAX_PAYLOAD + 1))
      results_for(names, { exists: true })
    end

    response = stat_call

    expect(wrapper.published).to be_empty
    expect(response.errors.values.map(&:error_kind).uniq).to eq([:payload_too_large])
    expect(response.errors[node1].error_message).to include("The file_transfer.stat /x request to #{node1} was not sent", '1048577 byte message',
      'Lower the message data size')
  end
end
