# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Sizing do
  # A round limit: the five percent reserve is 50,000 bytes.
  let(:max_payload) { 1_000_000 }
  let(:sizing) { described_class.new(max_payload: max_payload, chunk_size: 2_000_000) }

  describe '#calibrate' do
    it 'fits the chunk under the limit after the reserve, the envelope, and the wire expansion' do
      sizing.calibrate(envelope: 4_000, expansion: 2.0)

      # (1,000,000 - 50,000 - 4,000) content bytes at two wire bytes each.
      expect(sizing.chunk_bytes).to eq(473_000)
      expect(sizing).to be_calibrated
      expect(sizing).to be_usable
    end

    it 'never exceeds the chunk size it was given' do
      capped = described_class.new(max_payload: max_payload, chunk_size: 65_536)
      capped.calibrate(envelope: 4_000, expansion: 2.0)

      expect(capped.chunk_bytes).to eq(65_536)
    end

    it 'is unusable when the limit leaves less than the minimum chunk' do
      tiny = described_class.new(max_payload: 40_000, chunk_size: 2_000_000)
      tiny.calibrate(envelope: 30_000, expansion: 2.0)

      expect(tiny).not_to be_usable
    end
  end

  describe '#fallback' do
    it 'divides the limit after the reserve by a conservative factor when nothing was measured' do
      sizing.fallback

      expect(sizing.chunk_bytes).to eq(380_000)
      expect(sizing).not_to be_calibrated
    end
  end

  describe '#shrink_by_overshoot' do
    it 'removes the overshoot in content bytes plus a one percent cushion' do
      sizing.calibrate(envelope: 4_000, expansion: 2.0)

      sizing.shrink_by_overshoot(10_000)

      expect(sizing.chunk_bytes).to eq(473_000 - 5_000 - 4_730)
    end

    it 'treats the overshoot as content bytes when the expansion is unknown' do
      sizing.fallback

      sizing.shrink_by_overshoot(10_000)

      expect(sizing.chunk_bytes).to eq(380_000 - 10_000 - 3_800)
    end

    it 'stops at zero when the overshoot is larger than the chunk' do
      sizing.fallback

      sizing.shrink_by_overshoot(2_000_000)

      expect(sizing.chunk_bytes).to eq(0)
      expect(sizing).not_to be_usable
    end
  end

  describe '#shrink_blind' do
    it 'takes a fifth off the chunk' do
      sizing.calibrate(envelope: 4_000, expansion: 2.0)

      sizing.shrink_blind

      expect(sizing.chunk_bytes).to eq(378_400)
    end
  end

  describe '#reply_bytes' do
    before { sizing.calibrate(envelope: 4_000, expansion: 2.0) }

    it 'asks for a quarter of the chunk until replies have been measured' do
      expect(sizing.reply_bytes(measurable: true)).to eq(118_250)
    end

    it 'asks for a third of the chunk when replies cannot be measured at all' do
      expect(sizing.reply_bytes(measurable: false)).to eq(157_666)
    end

    it 'fits the reply under the limit after the reserve once the reply expansion is known' do
      sizing.record_replies(600_000, 200_000, 200_000)

      expect(sizing.reply_expansion).to eq(3.0)
      expect(sizing.reply_bytes(measurable: true)).to eq(316_666)
    end

    it 'keeps the largest reply expansion seen' do
      sizing.record_replies(600_000, 200_000, 200_000)
      sizing.record_replies(150_000, 100_000, 100_000)

      expect(sizing.reply_expansion).to eq(3.0)
    end

    it 'ignores a measurement without content' do
      sizing.record_replies(1_000, 0, 4_096)

      expect(sizing.reply_expansion).to be_nil
    end

    it 'ignores a round that carried less than half of what it asked for' do
      # One byte against a whole envelope would read as an expansion of
      # thousands and starve every later round.
      sizing.record_replies(2_001, 1, 4_096)

      expect(sizing.reply_expansion).to be_nil
      expect(sizing.reply_bytes(measurable: true)).to eq(118_250)
    end

    it 'never asks for more than the chunk' do
      sizing.record_replies(220_000, 200_000, 200_000)

      expect(sizing.reply_bytes(measurable: true)).to eq(473_000)
    end

    it 'never asks for less than the reply minimum' do
      sizing.record_replies(1_000_000_000, 100_000, 100_000)

      expect(sizing.reply_bytes(measurable: true)).to eq(described_class::MINIMUM_REPLY)
    end

    it 'asks for less after a blind failure even while the reply expansion is the binding term' do
      sizing.record_replies(600_000, 200_000, 200_000)
      before = sizing.reply_bytes(measurable: true)

      sizing.shrink_blind

      expect(before).to eq(316_666)
      expect(sizing.reply_bytes(measurable: true)).to eq(253_332)
    end

    it 'stops being usable for replies once blind failures push the ceiling under the minimum' do
      sizing.record_replies(600_000, 200_000, 200_000)
      shrinks = 0
      while sizing.reply_usable?
        sizing.reply_bytes(measurable: true)
        sizing.shrink_blind
        shrinks += 1
      end

      # 316,666 loses a fifth twenty times before it falls under 4,096.
      expect(shrinks).to eq(20)
    end
  end

  describe '#summary' do
    it 'names the chunk, the limit, and the measured expansion once calibrated' do
      sizing.calibrate(envelope: 4_000, expansion: 2.0)

      expect(sizing.summary).to eq('chunks of 473000 bytes (broker limit 1000000, envelope 4000, 2.00 wire bytes per content byte, chunk size 2000000)')
    end

    it 'says the sizing was not probed after a fallback' do
      sizing.fallback

      expect(sizing.summary).to include('sizing not probed')
    end
  end
end
