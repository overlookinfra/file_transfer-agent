# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Sizing do
  # A round limit, so the five percent reserve is 50,000 bytes.
  let(:max_payload) { 1_000_000 }
  let(:sizing) { described_class.new(max_payload: max_payload, chunk_size: 2_000_000) }

  it 'fits the chunk under the limit after the reserve at the wire expansion' do
    # 950,000 wire bytes at 2.5 per content byte.
    expect(sizing.chunk_bytes).to eq(380_000)
    expect(sizing).to be_usable
  end

  it 'never exceeds the chunk size it was given' do
    capped = described_class.new(max_payload: max_payload, chunk_size: 65_536)

    expect(capped.chunk_bytes).to eq(65_536)
  end

  it 'asks for a third of the chunk in a reply' do
    expect(sizing.reply_bytes).to eq(126_666)
  end

  it 'is usable when the limit leaves exactly the minimum chunk' do
    # 43,116 less its 2,156 byte reserve is 40,960 wire bytes, which is
    # 16,384 content bytes at 2.5 per byte.
    exact = described_class.new(max_payload: 43_116, chunk_size: 2_000_000)

    expect(exact.chunk_bytes).to eq(described_class::MINIMUM_CHUNK)
    expect(exact).to be_usable
  end

  it 'is unusable when the limit leaves less than the minimum chunk' do
    tiny = described_class.new(max_payload: 43_115, chunk_size: 2_000_000)

    expect(tiny).not_to be_usable
  end

  it 'names the chunk, the reply, the limit, and the chunk size' do
    expect(sizing.summary).to eq('chunks of 380000 bytes and replies of 126666 bytes (broker limit 1000000, chunk size 2000000)')
  end
end
