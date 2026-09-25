# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::PublishGuard do
  let(:wrapper) { FakeNatsWrapper.new(1_000) }
  let(:connection) { FakeConnection.new(wrapper) }
  let(:log) { FakeLogger.new }
  let(:guard) { described_class.new(connection, log) }

  it 'sets the limit for the block only and remembers the largest message published under it' do
    limit_inside = nil

    guard.guarding(1_000) do
      limit_inside = MCollective::Util::FileTransfer::PublishHook.limit
      wrapper.publish('subject', 'x' * 200)
      wrapper.publish('subject', 'x' * 700)
    end

    expect(limit_inside).to eq(1_000)
    expect(MCollective::Util::FileTransfer::PublishHook.limit).to be_nil
    expect(guard.largest_published).to eq(700)
    expect(wrapper.published).to eq([200, 700])
  end

  it 'clears the limit when the block raises' do
    expect { guard.guarding(1_000) { wrapper.publish('subject', 'x' * 1_001) } }
      .to raise_error(MCollective::Util::FileTransfer::PayloadTooLarge)

    expect(MCollective::Util::FileTransfer::PublishHook.limit).to be_nil
    expect(wrapper.published).to be_empty
  end

  context 'without a wrapper to hook' do
    let(:connection) { FakeConnection.new(nil) }

    it 'runs the block unguarded and warns once naming the reason' do
      ran = 0

      2.times { guard.guarding(1_000) { ran += 1 } }

      expect(ran).to eq(2)
      expect(log.once_ids).to eq(['file_transfer_guard_unavailable', 'file_transfer_guard_unavailable'])
      expect(log.once_messages.first).to include('has no publish method', 'would drop the connection')
    end
  end
end
