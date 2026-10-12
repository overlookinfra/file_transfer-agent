# frozen_string_literal: true

require 'spec_helper'

load AGENT unless defined?(FileTransfer::Agent)

# The Windows rule for the destination's last component, which no run of
# the agent process on this host can reach.
RSpec.describe 'the file_transfer put action on Windows' do
  let(:workdir) { Dir.mktmpdir('file_transfer-windows') }

  before { stub_const('FileTransfer::WINDOWS', true) }

  after { FileUtils.remove_entry_secure(workdir) }

  def put(destination)
    request = { 'action' => 'put', 'data' => { 'destination' => destination, 'token' => '0123456789abcdef', 'offset' => 0, 'data' => '' } }
    FileTransfer::Agent.new(request).reply
  end

  {
    'a device name' => 'CON',
    'a device name with an extension' => 'COM1.txt',
    'a colon' => 'a:b',
    'a trailing dot' => 'name.',
    'a trailing space' => 'name ',
  }.each do |description, name|
    it "refuses a destination whose last component carries #{description} and writes nothing" do
      reply = put(File.join(workdir, name))

      expect(reply['statuscode']).to eq(4)
      expect(reply['statusmsg']).to include('on Windows')
      expect(Dir.children(workdir)).to be_empty
    end
  end

  it 'accepts a last component that only begins like a device name' do
    reply = put(File.join(workdir, 'CONSOLE'))

    expect(reply['statuscode']).to eq(0)
    expect(Dir.children(workdir)).to eq(['.file_transfer-0123456789abcdef'])
  end
end
