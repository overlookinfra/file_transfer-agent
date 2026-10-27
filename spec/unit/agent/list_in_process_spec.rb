# frozen_string_literal: true

require 'spec_helper'

load AGENT unless defined?(FileTransfer::Agent)

# The cases no run of the agent process can set up: an entry that vanishes
# between the walk and its description, a file deleted during its digest,
# the reply limit, and a directory whose resolved path ends in a slash, as
# a root does.
RSpec.describe 'the file_transfer list action in process' do
  let(:workdir) { Dir.mktmpdir('file_transfer-list') }
  let(:max_bytes) { 100_000 }
  let(:checksum) { false }
  let(:agent) do
    FileTransfer::Agent.new({ 'action' => 'list', 'data' => { 'path' => workdir, 'max_bytes' => max_bytes, 'checksum' => checksum } })
  end

  before do
    File.write(File.join(workdir, 'a.txt'), 'a')
    File.write(File.join(workdir, 'b.txt'), 'b')
  end

  after { FileUtils.remove_entry_secure(workdir) }

  def entry_names(reply)
    reply['data']['entries'].map { |entry| entry['name'] }
  end

  it 'leaves out an entry that vanished before it was described' do
    allow(File).to receive(:lstat).and_wrap_original do |original, path|
      raise Errno::ENOENT, path if File.basename(path) == 'a.txt'

      original.call(path)
    end

    reply = agent.reply

    expect(reply['statuscode']).to eq(0)
    expect(entry_names(reply)).to eq(['b.txt'])
  end

  context 'with checksum' do
    let(:checksum) { true }

    it 'fails for a file deleted during its digest, since a download would fail on it later anyway' do
      allow(agent).to receive(:digest_file).and_wrap_original do |original, path|
        original.call(path).tap { File.delete(path) if File.basename(path) == 'a.txt' }
      end

      reply = agent.reply

      expect(reply['statuscode']).to eq(1)
      expect(reply['statusmsg']).to include('Errno::ENOENT', 'a.txt')
    end
  end

  context 'with a max_bytes above the reply limit' do
    let(:max_bytes) { 2**62 }

    it 'limits the listing to the reply limit' do
      stub_const('FileTransfer::MAX_REPLY_BYTES', 100)

      reply = agent.reply

      expect(reply['statuscode']).to eq(1)
      expect(reply['statusmsg']).to include("The listing of #{workdir} does not fit in 100 bytes")
    end
  end

  it 'names entries relative to a directory whose resolved path ends in a slash, as a root does' do
    allow(File).to(receive(:realpath).and_wrap_original { |original, path| "#{original.call(path)}/" })

    reply = agent.reply

    expect(reply['statuscode']).to eq(0)
    expect(entry_names(reply)).to eq(['a.txt', 'b.txt'])
  end
end
