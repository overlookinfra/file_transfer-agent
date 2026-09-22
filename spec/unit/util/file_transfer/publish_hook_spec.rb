# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::PublishHook do
  # A wrapper the hook is prepended onto, standing in for the NATS wrapper.
  let(:wrapper_class) do
    Class.new do
      attr_reader :sent

      def initialize
        @sent = []
      end

      def publish(_destination, payload, _reply = nil)
        @sent << payload
      end
    end
  end
  let(:wrapper) { wrapper_class.new }

  before { described_class.install(wrapper_class) }

  after do
    described_class.probing = false
    described_class.limit = nil
  end

  it 'installs once' do
    described_class.install(wrapper_class)

    expect(wrapper_class.ancestors.count(described_class)).to eq(1)
  end

  it 'passes a message through when neither probing nor limited' do
    wrapper.publish('subject', 'payload')

    expect(wrapper.sent).to eq(['payload'])
  end

  it 'records the size while probing and abandons the send' do
    described_class.probing = true

    expect { wrapper.publish('subject', 'x' * 123) }.to raise_error(MCollective::Util::FileTransfer::ProbeCaptured)
    expect(described_class.probed_size).to eq(123)
    expect(wrapper.sent).to be_empty
  end

  it 'refuses a message over the limit before it is sent, naming the overshoot' do
    described_class.limit = 100

    expect { wrapper.publish('subject', 'x' * 130) }.to raise_error(MCollective::Util::FileTransfer::PayloadTooLarge) { |error|
      expect(error.size).to eq(130)
      expect(error.limit).to eq(100)
      expect(error.overshoot).to eq(30)
    }
    expect(wrapper.sent).to be_empty
  end

  it 'sends a message at the limit' do
    described_class.limit = 100

    wrapper.publish('subject', 'x' * 100)

    expect(wrapper.sent.length).to eq(1)
  end
end
