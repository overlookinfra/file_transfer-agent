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
end
