# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Sizing do
  let(:rpc) { instance_double(MCollective::Util::FileTransfer::Rpc) }
  let(:log) { FakeLogger.new }
  let(:identity) { 'node1.example.com' }
  # A round limit, so the five percent reserve is 50,000 bytes.
  let(:sizing) { described_class.new(max_payload: 1_000_000, chunk_size: nil, rpc: rpc, identity: identity, logger: log) }
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
    allow(rpc).to receive(:request_bytes) { |args, _identity| request_for(args) }
  end

  it 'keeps five percent of the limit back' do
    expect(sizing.budget).to eq(950_000)
  end

  it 'encodes as the connector does, four characters per three bytes and an escaped newline per sixty' do
    expect(described_class.encoded_bytes(0)).to eq(0)
    expect(described_class.encoded_bytes(300)).to eq(414)
    expect(described_class.encoded_bytes(301)).to eq(418)
  end

  it 'fits the most content whose request stays within the budget' do
    content = sizing.content_bytes('app.tar', '/opt/app/app.tar')

    expect(sizing.wire_bytes(content, 'app.tar', '/opt/app/app.tar')).to be <= 950_000
    expect(sizing.wire_bytes(content + 3, 'app.tar', '/opt/app/app.tar')).to be > 950_000
  end

  it 'never exceeds the chunk size it was given' do
    capped = described_class.new(max_payload: 1_000_000, chunk_size: 65_536, rpc: rpc, identity: identity, logger: log)

    expect(capped.content_bytes('app.tar', '/opt/app/app.tar')).to eq(65_536)
  end

  it 'measures an empty request and then the sized one, both as a final chunk to the destination for the identity' do
    measured = []
    allow(rpc).to receive(:request_bytes) do |args, node|
      measured << [args, node]
      request_for(args)
    end

    content = sizing.content_bytes('app.tar', '/opt/app/app.tar')

    expect(measured.map { |args, _node| content_of(args) }).to eq([0, content])
    expect(measured.map(&:last).uniq).to eq([identity])
    args = measured.first.first
    expect(args).to include(name: 'app.tar', destination: '/opt/app/app.tar', final: true, mode: '0777')
    expect(args[:session].length).to eq(36)
    expect(args[:sha256].length).to eq(64)
    expect(args[:offset]).to be > 2**40
  end

  it 'answers the minimum chunk, and the two bytes its last base64 group has room for, when the limit just allows it' do
    # 34,906 less five percent is 33,160 bytes, what a request of 16,384
    # content bytes weighs in the fake's model.
    exact = described_class.new(max_payload: 34_906, chunk_size: nil, rpc: rpc, identity: identity, logger: log)

    expect(exact.content_bytes('a', 'b')).to eq(16_386)
  end

  it 'answers zero when the limit leaves less than the minimum chunk' do
    tiny = described_class.new(max_payload: 34_905, chunk_size: nil, rpc: rpc, identity: identity, logger: log)

    expect(tiny.content_bytes('a', 'b')).to eq(0)
  end

  it 'takes the excess off the content and says so once when the sized request weighs more than computed' do
    allow(rpc).to receive(:request_bytes) do |args, _identity|
      request = request_for(args)
      next request if content_of(args).zero?

      MCollective::Util::FileTransfer::Connection::Request.new(signed_bytes: request.signed_bytes, wire_bytes: request.wire_bytes + 5_000)
    end

    content = sizing.content_bytes('app.tar', '/opt/app/app.tar')

    expect(sizing.wire_bytes(content, 'app.tar', '/opt/app/app.tar')).to be <= 950_000
    expect(log.once_ids).to eq(['file_transfer_sizing_mismatch'])
    expect(log.once_messages.first).to include('frames requests differently')
  end

  it 'names the budget, the limit, and the chunk size' do
    capped = described_class.new(max_payload: 1_000_000, chunk_size: 2_000_000, rpc: rpc, identity: identity, logger: log)

    expect(capped.summary).to eq('950000 usable bytes of the 1000000 byte broker limit (chunk size 2000000)')
  end
end
