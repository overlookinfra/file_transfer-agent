# frozen_string_literal: true

require 'spec_helper'
require 'mcollective/util/indifferent_hash'

# The library over the real agent, one process per request as the Choria
# server runs it, with every reply read the way the gem reads one off the
# wire. The other library specs write the replies by hand, so a reply field
# that the agent and its specs rename together would only show here.
RSpec.describe MCollective::Util::FileTransfer::Client do
  include_context 'with an agent root'
  include_context 'with a file transfer client'

  let(:download_dir) { Dir.mktmpdir('file_transfer-round-trip', workdir) }

  before do
    [:put, :abort, :stat, :get, :list, :mkdir].each do |action|
      rpc.on(action) { |args, names| names.map { |name| result_from_agent(name, action, args) } }
    end
  end

  # The security plugin parses a reply into IndifferentHash objects, so the
  # nested hashes of a listing read by symbol as they do in production.
  def result_from_agent(name, action, args)
    reply = run_agent(action.to_s, JSON.parse(JSON.generate(args)))
    data = JSON.parse(JSON.generate(reply.raw), object_class: MCollective::Util::IndifferentHash)['data']
    MCollective::RPC::Result.new('file_transfer', action.to_s, sender: name, statuscode: reply.statuscode, statusmsg: reply.statusmsg, data: data)
  end

  it 'uploads a file through the agent and downloads it back unchanged' do
    content = SecureRandom.random_bytes(40_000)
    source = local_file('source.bin', content)
    destination = File.join(workdir, 'delivered.bin')

    uploaded = client.upload(source, destination, [node1])

    expect(uploaded[node1]).to be_success
    expect(uploaded[node1].path).to eq(destination)
    expect(File.binread(destination)).to eq(content)

    downloaded = client.download(destination, { node1 => download_dir })

    expect(downloaded[node1]).to be_success
    expect(File.binread(File.join(download_dir, 'delivered.bin'))).to eq(content)
    # The upload stats the destination first to learn whether it is a directory.
    expect(rpc.calls.map(&:first)).to eq([:stat, :put, :put, :put, :stat, :get, :get, :get])
    expect(temp_files(workdir)).to be_empty
    expect(temp_files(download_dir)).to be_empty
  end

  it 'uploads a directory tree through the agent and downloads it back' do
    tree = File.join(workdir, 'tree')
    FileUtils.mkdir_p(File.join(tree, 'sub'))
    File.write(File.join(tree, 'top.txt'), 'top')
    File.write(File.join(tree, 'sub', 'inner.txt'), 'inner')
    destination = File.join(workdir, 'delivered')

    uploaded = client.upload(tree, destination, [node1])

    expect(uploaded[node1]).to be_success
    expect(File.read(File.join(destination, 'top.txt'))).to eq('top')
    expect(File.read(File.join(destination, 'sub', 'inner.txt'))).to eq('inner')

    downloaded = client.download(destination, { node1 => download_dir })

    expect(downloaded[node1]).to be_success
    expect(downloaded[node1].path).to eq(File.join(download_dir, 'delivered'))
    expect(File.read(File.join(download_dir, 'delivered', 'top.txt'))).to eq('top')
    expect(File.read(File.join(download_dir, 'delivered', 'sub', 'inner.txt'))).to eq('inner')
    expect(rpc.calls.map(&:first)).to include(:mkdir, :list)
  end
end
