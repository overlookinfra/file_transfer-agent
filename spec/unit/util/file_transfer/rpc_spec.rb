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
    expect(response.errors[node1].message).to eq("The file_transfer.stat /x call on #{node1} failed: Permission denied")
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
    expect(response.errors[node2].kind).to eq(:transfer_failed)
    expect(response.errors[node2].message).to include('answered without usable data')
  end

  it 'reports a reply without a status code as a transfer failure of that node only' do
    stub_stat do |_args, names|
      names.map { |name| rpc_result(name, { exists: true }, statuscode: name == node2 ? nil : 0) }
    end

    response = stat_call

    expect(response.responded).to eq(node1 => { exists: true })
    expect(response.errors.keys).to eq([node2])
    expect(response.errors[node2].kind).to eq(:transfer_failed)
    expect(response.errors[node2].message).to eq("The file_transfer.stat /x call on #{node2} answered without a status code")
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

  it 'returns an empty response without a call when there are no identities' do
    response = stat_call([])

    expect(response.responded).to be_empty
    expect(response.errors).to be_empty
    expect(connection.calls).to be_empty
  end

  it 'waits the DDL timeout for replies and for publishing when the rpc timeout is below it, and names both in a silence' do
    stub_stat { |_args, names| results_for(names - [node2], { exists: true }) }

    response = stat_call

    expect(connection.calls).to eq([{ agent: 'file_transfer', identities: nodes, timeout: 120, publish_timeout: 120 }])
    expect(response.errors[node2].kind).to eq(:no_response)
    expect(response.errors[node2].message).to eq(
      "No response from #{node2} for file_transfer.stat /x within 120 seconds. If the node is up, its server may have stopped " \
      'the agent at the DDL timeout of 120 seconds.'
    )
  end

  context 'with a DDL that declares a timeout of 77 seconds' do
    let(:ddl_timeout) { 77 }

    it 'waits the timeout that the DDL declares' do
      stub_stat { |_args, names| results_for(names - [node2], { exists: true }) }

      response = stat_call

      expect(connection.calls.first).to include(timeout: 77, publish_timeout: 77)
      expect(response.errors[node2].message).to include('within 77 seconds', 'the DDL timeout of 77 seconds')
    end
  end

  context 'with an rpc timeout above the DDL timeout' do
    let(:agent_rpc) { described_class.new(connection, log, 300) }

    it 'waits the rpc timeout for replies and for publishing, and names both timeouts in a silence' do
      stub_stat { |_args, names| results_for(names - [node2], { exists: true }) }

      response = stat_call

      expect(connection.calls.first).to include(timeout: 300, publish_timeout: 300)
      expect(response.errors[node2].message).to include('within 300 seconds', 'the DDL timeout of 120 seconds')
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

  it 'holds every message of a call under the broker limit and lifts the limit after' do
    stub_stat do |_args, names|
      wrapper.publish('subject', 'x' * max_payload)
      results_for(names, { exists: true })
    end

    stat_call
    wrapper.publish('subject', 'x' * (max_payload + 1))

    expect(wrapper.published).to eq([max_payload, max_payload + 1])
  end

  context 'with a message over the broker limit' do
    let(:max_payload) { 1_000 }

    it 'fails every node with payload_too_large when the guard refuses the message, naming the message data size as the remedy' do
      stub_stat do |_args, names|
        wrapper.publish('subject', 'x' * 1_500)
        results_for(names, { exists: true })
      end

      response = stat_call

      expect(wrapper.published).to be_empty
      expect(response.errors.values.map(&:kind).uniq).to eq([:payload_too_large])
      expect(response.errors[node1].message).to include("The file_transfer.stat /x request to #{node1} was not sent", '1500 byte message',
        'Lower the message data size')
    end
  end

  describe 'the broker limit' do
    before { stub_stat { |_args, names| results_for(names, { exists: true }) } }

    it 'is read from the connection by the first call, once' do
      allow(connection).to receive(:max_payload).and_call_original

      stat_call
      stat_call
      agent_rpc.upload_batch_size

      expect(connection).to have_received(:max_payload).once
      expect(agent_rpc.max_payload).to eq(max_payload)
    end

    it 'is unknown before the first call, so every size that derives from it raises instead of guessing' do
      [:max_payload, :message_data_bytes, :upload_batch_size, :download_batch_size].each do |size|
        expect { agent_rpc.public_send(size) }.to raise_error(RuntimeError, 'No call has run yet, so the broker message size limit has not been read')
      end
      expect(log.once_ids).to be_empty
    end

    it 'is not needed for a message data size the caller chose' do
      expect(described_class.new(connection, log, 30, message_data_kib: 16).message_data_bytes).to eq(16_384)
    end

    it 'is assumed to be 1 MiB, with one warning, when the connection cannot read it' do
      allow(connection).to receive(:max_payload).and_raise(NoMethodError, 'undefined method server_info for nil')

      stat_call

      expect(agent_rpc.max_payload).to eq(1_048_576)
      expect(log.once_ids).to eq(['file_transfer_max_payload_unknown'])
      expect(log.once_messages.first).to include('NoMethodError', 'assumes 1048576 bytes')
    end

    it 'is assumed to be 1 MiB when the server info gives no positive integer' do
      allow(connection).to receive(:max_payload).and_return(nil)

      stat_call

      expect(agent_rpc.max_payload).to eq(1_048_576)
      expect(log.once_messages.first).to include('the server info says nil')
    end
  end

  describe 'the batch sizes' do
    # The sizes derive from the limit, which the first call reads.
    before do
      stub_stat { |_args, names| results_for(names, { exists: true }) }
      stat_call
    end

    it 'publishes a chunk to the largest number of nodes that keeps a batch under the memory bound at the limit' do
      expect(agent_rpc.upload_batch_size).to eq(256)
    end

    it 'asks the largest number of nodes per download round whose replies, each at most the limit, stay under three quarters of the broker backlog' do
      expect(agent_rpc.download_batch_size).to eq(48)
    end

    context 'with a limit above the memory bound' do
      let(:max_payload) { 512 * 1024 * 1024 }

      it 'publishes a chunk to one node at a time and asks one node per download round' do
        expect(agent_rpc.upload_batch_size).to eq(1)
        expect(agent_rpc.download_batch_size).to eq(1)
      end
    end

    context 'with an upload batch size of its own' do
      let(:agent_rpc) { described_class.new(connection, log, 30, upload_batch_size: 3) }

      it 'publishes a chunk to that many nodes, whatever the limit says' do
        expect(agent_rpc.upload_batch_size).to eq(3)
      end
    end
  end
end
