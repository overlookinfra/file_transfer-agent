# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::DefaultLogger do
  let(:logger) { described_class.new }

  it 'logs debug and warn lines through the MCollective logger' do
    expect(MCollective::Log).to receive(:debug).with('probing')
    expect(MCollective::Log).to receive(:warn).with('shrinking')

    logger.debug('probing')
    logger.warn('shrinking')
  end

  it 'warns once per id' do
    expect(MCollective::Log).to receive(:warn).with('first').once

    logger.warn_once('reduction', 'first')
    logger.warn_once('reduction', 'second')
  end

  it 'warns again for another id' do
    expect(MCollective::Log).to receive(:warn).with('first').once
    expect(MCollective::Log).to receive(:warn).with('second').once

    logger.warn_once('reduction', 'first')
    logger.warn_once('fallback', 'second')
  end
end
