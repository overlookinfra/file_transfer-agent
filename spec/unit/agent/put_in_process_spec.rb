# frozen_string_literal: true

require 'spec_helper'

load AGENT unless defined?(FileTransfer::Agent)

# What no run of the agent process on this host can reach: the Windows
# rule for the destination's last component, and a disk that fills under
# a buffered write.
RSpec.describe 'the file_transfer put action in process' do
  let(:workdir) { Dir.mktmpdir('file_transfer-in-process') }

  after { FileUtils.remove_entry_secure(workdir) }

  def put(destination, data: '')
    request = { 'action' => 'put', 'data' => { 'destination' => destination, 'token' => '0123456789abcdef', 'offset' => 0, 'data' => data } }
    FileTransfer::Agent.new(request).reply
  end

  describe 'on Windows' do
    before { stub_const('FileTransfer::WINDOWS', true) }

    {
      'a device name' => 'CON',
      'a device name with an extension' => 'COM1.txt',
      'a colon' => 'a:b',
      'a trailing dot' => 'name.',
      'a trailing space' => 'name ',
    }.each do |description, name|
      it "refuses a destination whose last component contains #{description} and writes nothing" do
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

  describe 'on a disk that fills' do
    # Ruby buffers a write under 8 KiB, so a full disk refuses it at the
    # flush, and the close after that retries the buffer and fails again.
    it 'removes the temporary file when the flush and then the close fail' do
      allow(File).to receive(:new).and_wrap_original do |original, *args|
        file = original.call(*args)
        allow(file).to receive(:flush).and_raise(Errno::ENOSPC, 'the disk')
        allow(file).to receive(:close).and_wrap_original do |close|
          close.call
          raise Errno::ENOSPC, 'the disk'
        end
        file
      end

      reply = put(File.join(workdir, 'file.bin'), data: ['partial'].pack('m0'))

      expect(reply['statuscode']).to eq(1)
      expect(reply['statusmsg']).to include('Errno::ENOSPC')
      expect(Dir.children(workdir)).to be_empty
    end
  end
end
