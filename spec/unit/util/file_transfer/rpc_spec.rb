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

  it 'holds every message of a call under the broker limit and lifts the limit after' do
    seen = nil
    stub_stat do |_args, names|
      seen = MCollective::Util::FileTransfer::PublishGuard.limit
      wrapper.publish('subject', 'x' * 500)
      results_for(names, { exists: true })
    end

    stat_call

    expect(seen).to eq(max_payload)
    expect(MCollective::Util::FileTransfer::PublishGuard.limit).to be_nil
    expect(wrapper.published).to eq([500])
  end

  context 'with a message over the broker limit' do
    let(:max_payload) { 1_000 }

    it 'fails every node with payload_too_large when the guard refuses the message, naming the chunk size as the remedy' do
      stub_stat do |_args, names|
        wrapper.publish('subject', 'x' * 1_500)
        results_for(names, { exists: true })
      end

      response = stat_call

      expect(wrapper.published).to be_empty
      expect(MCollective::Util::FileTransfer::PublishGuard.limit).to be_nil
      expect(response.errors.values.map(&:kind).uniq).to eq([:payload_too_large])
      expect(response.errors[node1].message).to include("file_transfer.stat /x on #{node1} was not sent", '1500 byte message', 'Lower the chunk size')
    end
  end

  describe 'the broker limit' do
    it 'is read from the connection once' do
      allow(connection).to receive(:max_payload).and_call_original

      agent_rpc.max_payload
      agent_rpc.upload_batch_size

      expect(connection).to have_received(:max_payload).once
    end

    it 'is assumed to be 1 MiB, with one warning, when the connection cannot read it' do
      allow(connection).to receive(:max_payload).and_raise(NoMethodError, 'undefined method server_info for nil')

      expect(agent_rpc.max_payload).to eq(1_048_576)
      expect(log.once_ids).to eq(['file_transfer_max_payload_unknown'])
      expect(log.once_messages.first).to include('NoMethodError', 'assumes 1048576 bytes')
    end

    it 'is assumed to be 1 MiB when the server info gives no positive integer' do
      allow(connection).to receive(:max_payload).and_return(nil)

      expect(agent_rpc.max_payload).to eq(1_048_576)
      expect(log.once_messages.first).to include('the server info says nil')
    end
  end

  describe 'the batch sizes' do
    it 'publishes a chunk to as many nodes as keep a batch under the memory bound at the limit' do
      expect(agent_rpc.upload_batch_size).to eq(256)
    end

    it 'asks as many nodes per download round as keep the replies, each at most the limit, under three quarters of the broker backlog' do
      expect(agent_rpc.download_batch_size).to eq(48)
    end

    context 'with a limit above the memory bound' do
      let(:max_payload) { 512 * 1024 * 1024 }

      it 'publishes a chunk to one node at a time and asks one node per download round' do
        expect(agent_rpc.upload_batch_size).to eq(1)
        expect(agent_rpc.download_batch_size).to eq(1)
      end
    end

    context 'with batch sizes of its own' do
      let(:agent_rpc) { described_class.new(connection, log, 30, upload_batch_size: 3, download_batch_size: 3) }

      it 'uses them when they fit' do
        expect(agent_rpc.upload_batch_size).to eq(3)
        expect(agent_rpc.download_batch_size).to eq(3)
        expect(log.once_ids).to be_empty
      end
    end

    context 'with a download batch size the limit leaves no room for' do
      let(:agent_rpc) { described_class.new(connection, log, 30, download_batch_size: 3) }
      let(:max_payload) { 32 * 1024 * 1024 }

      it 'reduces the batch to the bound with a warning naming the broker' do
        expect(agent_rpc.download_batch_size).to eq(1)
        expect(log.once_ids).to eq(['file_transfer_download_batch_bounded'])
        expect(log.once_messages.first).to include('batch size of 3 is reduced to 1', 'the broker holds for a connection')
      end
    end
  end
end
