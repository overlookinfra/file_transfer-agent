# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Sizing do
  let(:connection) { instance_double(MCollective::Util::FileTransfer::Connection, max_payload: 1_000_000) }
  let(:log) { FakeLogger.new }
  let(:identity) { 'node1.example.com' }
  let(:settings) { { chunk_size: nil, upload_batch_size: nil, download_batch_size: nil } }
  # A round limit, so the five percent reserve is 50,000 bytes.
  let(:sizing) { described_class.new(connection, log, **settings) }
  let(:envelope) { 2_000 }
  let(:framing) { 300 }

  def content_of(args)
    args[:data].unpack1('m0').bytesize
  end

  # A signed request is an envelope plus the base64 data, and the
  # transport adds framing around its outer encoding.
  def request_for(args)
    signed = envelope + args[:data].bytesize
    MCollective::Util::FileTransfer::Connection::Request.new(signed_bytes: signed, wire_bytes: framing + described_class.encoded_bytes(signed))
  end

  before do
    allow(connection).to receive(:request_bytes) { |_agent, _action, args, _identity| request_for(args) }
  end

  it 'keeps five percent of the limit back' do
    expect(sizing.budget).to eq(950_000)
  end

  it 'reads the limit from the connection once' do
    sizing.max_payload
    sizing.budget

    expect(connection).to have_received(:max_payload).once
  end

  it 'assumes the default limit and warns once when the connection cannot read it' do
    allow(connection).to receive(:max_payload).and_raise(NoMethodError, 'undefined method server_info for nil')

    expect(sizing.max_payload).to eq(1_048_576)
    expect(sizing.budget).to eq(996_147)
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

  it 'fits the most content whose request stays within the budget' do
    content = sizing.content_bytes('app.tar', '/opt/app/app.tar', identity)

    expect(sizing.wire_bytes(content, 'app.tar', '/opt/app/app.tar', identity)).to be <= 950_000
    expect(sizing.wire_bytes(content + 3, 'app.tar', '/opt/app/app.tar', identity)).to be > 950_000
  end

  context 'with a chunk size' do
    let(:settings) { { chunk_size: 65_536, upload_batch_size: nil, download_batch_size: nil } }

    it 'never exceeds the chunk size it was given' do
      expect(sizing.content_bytes('app.tar', '/opt/app/app.tar', identity)).to eq(65_536)
    end

    it 'names the budget, the limit, and the chunk size' do
      expect(sizing.summary).to eq('950000 usable bytes of the 1000000 byte broker limit (chunk size 65536)')
    end
  end

  it 'measures an empty request and then the sized one, both as a final put of the name to the destination for the identity' do
    measured = []
    allow(connection).to receive(:request_bytes) do |agent, action, args, node|
      measured << [agent, action, args, node]
      request_for(args)
    end

    content = sizing.content_bytes('app.tar', '/opt/app/app.tar', identity)

    expect(measured.map { |_agent, _action, args, _node| content_of(args) }).to eq([0, content])
    expect(measured.map { |agent, action, _args, node| [agent, action, node] }.uniq).to eq([['file_transfer', 'put', identity]])
    args = measured.first[2]
    expect(args).to include(name: 'app.tar', destination: '/opt/app/app.tar', final: true, mode: '0777')
    expect(args[:session].length).to eq(36)
    expect(args[:sha256].length).to eq(64)
    expect(args[:offset]).to be > 2**40
  end

  it 'answers the minimum chunk, and the two bytes its last base64 group has room for, when the limit just allows it' do
    # 34,906 less five percent is 33,160 bytes, what a request of 16,384
    # content bytes weighs in the fake's model.
    allow(connection).to receive(:max_payload).and_return(34_906)

    expect(sizing.content_bytes('a', 'b', identity)).to eq(16_386)
  end

  it 'answers zero when the limit leaves less than the minimum chunk' do
    allow(connection).to receive(:max_payload).and_return(34_905)

    expect(sizing.content_bytes('a', 'b', identity)).to eq(0)
  end

  it 'fails the identities with the limit and the direction when no chunk fits' do
    allow(connection).to receive(:max_payload).and_return(34_905)

    upload = sizing.too_small_failures(['node1', 'node2'], 'app.tar', :upload)
    download = sizing.too_small_failures(['node1'], '/var/log/app.log', :download)

    expect(upload.keys).to eq(['node1', 'node2'])
    expect(upload.values.map(&:kind).uniq).to eq([:payload_too_large])
    expect(upload['node2'].message).to eq("The broker's payload limit of 34905 bytes leaves less than 16384 bytes of file content per request, " \
                                          'so app.tar cannot be sent to node2')
    expect(download['node1'].message).to include('per reply, so /var/log/app.log cannot be fetched from node1')
  end

  it 'takes the excess off the content and says so once when the sized request weighs more than computed' do
    allow(connection).to receive(:request_bytes) do |_agent, _action, args, _identity|
      request = request_for(args)
      next request if content_of(args).zero?

      MCollective::Util::FileTransfer::Connection::Request.new(signed_bytes: request.signed_bytes, wire_bytes: request.wire_bytes + 5_000)
    end

    content = sizing.content_bytes('app.tar', '/opt/app/app.tar', identity)

    expect(sizing.wire_bytes(content, 'app.tar', '/opt/app/app.tar', identity)).to be <= 950_000
    expect(log.once_ids).to eq(['file_transfer_sizing_mismatch'])
    expect(log.once_messages.first).to include('frames requests differently')
  end

  it 'publishes a chunk to as many nodes as keep a batch under the memory bound at the limit' do
    expect(sizing.upload_batch_size).to eq(268)
  end

  it 'publishes a chunk to one node at a time when the limit is above the memory bound' do
    allow(connection).to receive(:max_payload).and_return(512 * 1024 * 1024)

    expect(sizing.upload_batch_size).to eq(1)
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

  it 'names the budget and the limit without a chunk size' do
    expect(sizing.summary).to eq('950000 usable bytes of the 1000000 byte broker limit (no chunk size)')
  end
end
