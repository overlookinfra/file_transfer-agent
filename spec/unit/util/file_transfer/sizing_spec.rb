# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Sizing do
  let(:rpc) { instance_double(MCollective::Util::FileTransfer::Rpc) }
  let(:identity) { 'node1.example.com' }
  # A round limit, so the five percent reserve is 50,000 bytes.
  let(:sizing) { described_class.new(max_payload: 1_000_000, chunk_size: 2_000_000, rpc: rpc, identity: identity) }

  def content_of(args)
    args[:data].unpack1('m0').bytesize
  end

  # A request weighs a fixed envelope plus its content at a wire expansion.
  before do
    allow(rpc).to receive(:request_bytes) { |args, _identity| 2_000 + (content_of(args) * 1.84).ceil }
  end

  it 'keeps five percent of the limit back' do
    expect(sizing.budget).to eq(950_000)
  end

  it 'fits the most content whose request stays within the budget' do
    content = sizing.content_bytes('app.tar', '/opt/app/app.tar')

    expect(sizing.wire_bytes(content, 'app.tar', '/opt/app/app.tar')).to be <= 950_000
    expect(sizing.wire_bytes(content + 3, 'app.tar', '/opt/app/app.tar')).to be > 950_000
  end

  it 'never exceeds the chunk size it was given' do
    capped = described_class.new(max_payload: 1_000_000, chunk_size: 65_536, rpc: rpc, identity: identity)

    expect(capped.content_bytes('app.tar', '/opt/app/app.tar')).to eq(65_536)
  end

  it 'measures a final chunk to the destination for the identity, the largest request a chunk takes' do
    measured = []
    allow(rpc).to receive(:request_bytes) { |args, node| measured << [args, node] and 3_000 }

    sizing.content_bytes('app.tar', '/opt/app/app.tar')

    expect(measured.length).to eq(1)
    args, node = measured.first
    expect(node).to eq(identity)
    expect(args).to include(name: 'app.tar', destination: '/opt/app/app.tar', final: true, mode: '0777')
    expect(args[:session].length).to eq(36)
    expect(args[:sha256].length).to eq(64)
    expect(args[:offset]).to be > 2**40
    expect(content_of(args)).to eq(2_000_000)
  end

  it 'answers the minimum chunk when the limit just leaves room for it' do
    # 33,840 less five percent is 32,148 bytes, and the minimum chunk of
    # 16,384 bytes weighs 32,147.
    exact = described_class.new(max_payload: 33_840, chunk_size: nil, rpc: rpc, identity: identity)

    expect(exact.content_bytes('a', 'b')).to eq(described_class::MINIMUM_CHUNK)
  end

  it 'answers zero when the limit leaves less than the minimum chunk' do
    tiny = described_class.new(max_payload: 33_838, chunk_size: nil, rpc: rpc, identity: identity)

    expect(tiny.content_bytes('a', 'b')).to eq(0)
  end

  it 'names the budget, the limit, and the chunk size' do
    expect(sizing.summary).to eq('950000 usable bytes of the 1000000 byte broker limit (chunk size 2000000)')
  end
end
