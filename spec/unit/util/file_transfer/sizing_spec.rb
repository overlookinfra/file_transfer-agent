# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe MCollective::Util::FileTransfer::Sizing do
  include_context 'with a file transfer client'

  let(:settings) { { chunk_size: nil, upload_batch_size: nil, download_batch_size: nil } }
  let(:sizing) { described_class.new(connection, log, **settings) }
  let(:name) { 'app.tar' }
  let(:destination) { '/opt/app/app.tar' }
  let(:size) { 40_000_000 }

  # The put the content would go out in, as the file sender builds its
  # final chunk, serialized for the check.
  def final_put(content, put_name = name, put_destination = destination, put_size = size)
    { session: 'x' * 36, name: put_name, offset: [put_size - 1, 0].max, data: encoded('x' * content), final: true,
      sha256: 'x' * 64, mode: '0777', destination: put_destination }.compact
  end

  def content
    sizing.content_bytes(name, [destination], nodes, size)
  end

  it 'answers the most content whose message, serialized as the gem builds it, fits the limit' do
    expect(serialized_wire(final_put(content))).to be <= max_payload
    expect(serialized_wire(final_put(content + 3))).to be > max_payload
  end

  it 'computes the wire size of a request as the serialized message weighs' do
    [0, 1, 16_384, 300_000, content].each do |bytes|
      expect(sizing.wire_bytes(bytes, name, destination, nodes, size)).to eq(serialized_wire(final_put(bytes)))
    end
  end

  it 'leaves room for the longest destination and the digits of the largest offset' do
    long = "/opt/#{'d' * 300}"
    fitted = sizing.content_bytes(name, ['/opt/app', long, nil], nodes, 10**12)

    expect(fitted).to be < content
    expect(serialized_wire(final_put(fitted, name, long, 10**12))).to be <= max_payload
    expect(serialized_wire(final_put(fitted + 3, name, long, 10**12))).to be > max_payload
  end

  it 'leaves out the destination for a file that stays in the session' do
    fitted = sizing.content_bytes(name, [nil, nil], nodes, size)

    expect(fitted).to be > content
    expect(serialized_wire(final_put(fitted, name, nil))).to be <= max_payload
    expect(serialized_wire(final_put(fitted + 3, name, nil))).to be > max_payload
  end

  context 'when the client is federated' do
    let(:connection) { FakeConnection.new(wrapper, federated: true) }
    let(:many) { Array.new(250) { |index| "node#{index}.#{'x' * (index % 7)}.example.com" } }

    it 'leaves room for the federation header carrying the longest identities a message can hold' do
      fitted = sizing.content_bytes(name, [destination], many, size)

      expect(fitted).to be < content
      expect(serialized_wire(final_put(fitted), many)).to be <= max_payload
      expect(serialized_wire(final_put(fitted + 3), many)).to be > max_payload
      expect(fitted).to eq(sizing.content_bytes(name, [destination], many.max_by(200, &:bytesize), size))
    end
  end

  it 'reads the limit from the connection once' do
    allow(connection).to receive(:max_payload).and_call_original

    sizing.content_bytes(name, [destination], nodes, size)
    sizing.upload_batch_size

    expect(connection).to have_received(:max_payload).once
  end

  it 'assumes the default limit and warns once when the connection cannot read it' do
    allow(connection).to receive(:max_payload).and_raise(NoMethodError, 'undefined method server_info for nil')

    expect(sizing.max_payload).to eq(1_048_576)
    expect(log.once_ids).to eq(['file_transfer_max_payload_unknown'])
    expect(log.once_messages.first).to include('NoMethodError', 'assumes 1048576 bytes')
  end

  it 'assumes the default limit when the server info gives no positive integer' do
    allow(connection).to receive(:max_payload).and_return(nil)

    expect(sizing.max_payload).to eq(1_048_576)
    expect(log.once_messages.first).to include('the server info says nil')
  end

  # The connector encodes with Base64.encode64, which is pack('m'), and
  # the transport JSON escapes the newlines it puts in. The two quotes
  # around the JSON string belong to the framing.
  it 'encodes as the connector does, four characters per three bytes and an escaped newline per sixty' do
    [0, 1, 2, 3, 44, 45, 46, 59, 60, 61, 300, 301, 4096, 786_432].each do |length|
      expect(described_class.encoded_bytes(length)).to eq(['x' * length].pack('m').to_json.bytesize - 2)
    end
  end

  context 'with a chunk size' do
    let(:settings) { { chunk_size: 65_536, upload_batch_size: nil, download_batch_size: nil } }

    it 'never exceeds the chunk size it was given' do
      expect(content).to eq(65_536)
    end

    it 'names the limit and the chunk size' do
      expect(sizing.summary).to eq('a 1048576 byte broker limit (chunk size 65536)')
    end
  end

  context 'with a limit that leaves less than the minimum chunk' do
    let(:max_payload) { 30_000 }

    it 'answers zero' do
      expect(content).to eq(0)
    end

    it 'fails the identities with the limit and the direction' do
      upload = sizing.too_small_failures(['node1', 'node2'], 'app.tar', :upload)
      download = sizing.too_small_failures(['node1'], '/var/log/app.log', :download)

      expect(upload.keys).to eq(['node1', 'node2'])
      expect(upload.values.map(&:kind).uniq).to eq([:payload_too_large])
      expect(upload['node2'].message).to eq("The broker's payload limit of 30000 bytes leaves less than 16384 bytes of file content per request, " \
                                            'so app.tar cannot be sent to node2')
      expect(download['node1'].message).to include('per reply, so /var/log/app.log cannot be fetched from node1')
    end
  end

  it 'publishes a chunk to as many nodes as keep a batch under the memory bound at the limit' do
    expect(sizing.upload_batch_size).to eq(256)
  end

  context 'with a limit above the memory bound' do
    let(:max_payload) { 512 * 1024 * 1024 }

    it 'publishes a chunk to one node at a time' do
      expect(sizing.upload_batch_size).to eq(1)
    end
  end

  context 'with an upload batch size' do
    let(:settings) { { chunk_size: nil, upload_batch_size: 3, download_batch_size: nil } }

    it 'publishes a chunk to that many nodes' do
      expect(sizing.upload_batch_size).to eq(3)
    end
  end

  it 'asks as many nodes per download round as keep the replies under three quarters of the broker backlog' do
    expect(sizing.download_batch_size(1_000_000)).to eq(50)
    expect(sizing.download_batch_size(64 * 1024 * 1024)).to eq(1)
  end

  context 'with a download batch size' do
    let(:settings) { { chunk_size: nil, upload_batch_size: nil, download_batch_size: 3 } }

    it 'asks that many nodes when they fit, and the bound with a warning when they do not' do
      expect(sizing.download_batch_size(1_000_000)).to eq(3)
      expect(log.once_ids).to be_empty

      expect(sizing.download_batch_size(20 * 1024 * 1024)).to eq(2)
      expect(log.once_ids).to eq(['file_transfer_download_batch_bounded'])
      expect(log.once_messages.first).to include('batch size of 3 is reduced to 2', 'the broker holds for a connection')
    end
  end

  it 'names the limit without a chunk size' do
    expect(sizing.summary).to eq('a 1048576 byte broker limit (no chunk size)')
  end
end
