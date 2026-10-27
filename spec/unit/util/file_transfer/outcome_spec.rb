# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Outcome do
  describe '.per_identity' do
    let(:refusal) { described_class.failure('b', :transfer_failed, 'refused') }

    it 'returns one outcome per identity in the order given, its failure or a success with its path' do
      outcomes = described_class.per_identity(['a', 'b', 'c'], { 'b' => refusal }, { 'c' => '/c', 'a' => '/a', 'b' => '/b' })

      expect(outcomes.keys).to eq(['a', 'b', 'c'])
      expect(outcomes['a']).to eq(described_class.success('a', '/a'))
      expect(outcomes['b']).to be(refusal)
      expect(outcomes['c']).to eq(described_class.success('c', '/c'))
    end

    it 'raises for an identity with neither a failure nor a path' do
      expect { described_class.per_identity(['a'], {}, {}) }.to raise_error(KeyError)
    end
  end
end
