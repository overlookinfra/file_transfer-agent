# frozen_string_literal: true

require 'spec_helper'

# The get rounds of a download, driven through Client#download so each
# example also sees where the verified copy is written. The stat before the
# rounds, the local checks and the trees are in download_spec.rb.
RSpec.describe MCollective::Util::FileTransfer::Receiver do
  include_context 'with a download client'

  context 'with a file larger than a reply' do
    let(:contents) { { node1 => 'a' * 40_000, node2 => 'b' * 100 } }

    it 'asks each node for a chunk of the message data size per round until its size is covered and places the verified copies' do
      stub_file_stats
      stub_get

      outcomes = client.download('/var/log/app.log', destination_dirs)

      expect(outcomes.values).to all(be_success)
      expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 40_000)
      expect(File.binread(File.join(dir_for(node2), 'app.log'))).to eq('b' * 100)
      expect(get_calls.map { |call| call[:max_bytes] }.uniq).to eq([16_384])
      expect(get_calls.map { |call| call[:offset] }).to eq([0, 16_384, 32_768])
      expect(get_calls.map { |call| call[:identities] }).to eq([nodes, [node1], [node1]])
    end
  end

  it 'reports a file whose content changed during the download and leaves nothing beside its destination' do
    # The same length, so the digest is the only thing that gives it away.
    stub_file_stats(node1 => 'c' * 12_000, node2 => 'b' * 100)
    stub_get

    outcomes = client.download('/var/log/app.log', destination_dirs)

    expect(outcomes[node1].error_kind).to eq(:checksum_mismatch)
    expect(outcomes[node1].error_message).to include('changed during the download')
    expect(Dir.children(dir_for(node1))).to be_empty
    expect(outcomes[node2]).to be_success
  end

  it 'fails the node whose copy cannot be flushed at its close and leaves nothing beside the destination' do
    stub_file_stats
    stub_get
    fail_close_of_temporary_files(Errno::ENOSPC)

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1].error_kind).to eq(:transfer_failed)
    expect(outcomes[node1].error_message).to include("#{File.join(dir_for(node1), 'app.log')} could not be written from #{node1}", 'Errno::ENOSPC')
    expect(Dir.children(dir_for(node1))).to be_empty
  end

  it 'still returns its outcomes and removes the copy when the close of a failed node\'s file raises' do
    # The same length, so the digest is the only thing that gives it away.
    stub_file_stats(node1 => 'c' * 100)
    stub_get(node1 => 'd' * 100)
    fail_close_of_temporary_files(Errno::EIO)

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1].error_kind).to eq(:checksum_mismatch)
    expect(Dir.children(dir_for(node1))).to be_empty
  end

  it 'asks no second round once the size its stat reported is covered' do
    stub_file_stats(node1 => 'a' * 100)
    stub_get_replies do |_args, _name|
      raise 'the client kept asking a node whose size was covered' if get_calls.length > 1

      { data: encoded('a' * 100), bytes: 100, size: 100 }
    end

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(get_calls.length).to eq(1)
    expect(outcomes[node1]).to be_success
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 100)
  end

  it 'asks nothing for an empty file and delivers it from its digest alone' do
    stub_file_stats(node1 => '')
    stub_get_replies { |_args, _name| raise 'the client asked for a chunk of an empty file' }

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(get_calls).to be_empty
    expect(outcomes[node1]).to be_success
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('')
  end

  it 'fails only the node whose get reply contains no status code' do
    stub_file_stats
    rpc.on(:get) do |args, names|
      names.map { |name| rpc_result(name, get_data(contents.fetch(name), args), statuscode: name == node2 ? nil : 0) }
    end

    outcomes = client.download('/var/log/app.log', destination_dirs)

    expect(outcomes[node1]).to be_success
    expect(outcomes[node2].error_kind).to eq(:transfer_failed)
    expect(outcomes[node2].error_message).to include('answered without a status code')
    expect(File.exist?(File.join(dir_for(node2), 'app.log'))).to be(false)
  end

  it 'fails a node whose reply contains more than the bytes the round asked for' do
    stub_file_stats
    stub_get_replies { |_args, _name| { data: encoded('x' * 20_000), bytes: 20_000, size: 100 } }

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1].error_kind).to eq(:transfer_failed)
    expect(outcomes[node1].error_message).to include('20000 bytes, more than the 16384 requested')
  end

  it 'fails a node whose reply is not valid base64' do
    stub_file_stats
    stub_get_replies { |_args, _name| { data: 'not base64!', bytes: 5, size: 100 } }

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1].error_kind).to eq(:transfer_failed)
    expect(outcomes[node1].error_message).to include("/var/log/app.log on #{node1} replied with data that is not base64")
  end

  context 'when a node stays silent for a get' do
    it 'reports it as not responding after one round' do
      stub_file_stats(node1 => 'a' * 30_000)
      rpc.on(:get) do |args, names|
        get_calls << args.merge(identities: names)
        []
      end

      outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

      expect(get_calls.map { |call| [call[:offset], call[:max_bytes]] }).to eq([[0, 16_384]])
      expect(outcomes[node1].error_kind).to eq(:no_response)
    end
  end

  it 'fails a node whose reply falls short of the size its stat reported and stops asking it' do
    stub_file_stats(node1 => 'a' * 40_000)
    stub_get_replies do |args, _name|
      content = args[:offset].zero? ? 'a' * 16_384 : 'a' * 100
      { data: encoded(content), bytes: content.bytesize, size: 40_000 }
    end

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(get_calls.map { |call| call[:offset] }).to eq([0, 16_384])
    expect(outcomes[node1].error_kind).to eq(:transfer_failed)
    expect(outcomes[node1].error_message).to include('100 bytes at offset 16384 where 23616 remained', 'shrank during the download')
    expect(File.exist?(File.join(dir_for(node1), 'app.log'))).to be(false)
  end

  it 'cuts a reply at the size that the stat reported, so a file that grew during the download verifies as it was described' do
    stub_file_stats(node1 => 'a' * 20_000)
    stub_get(node1 => ('a' * 20_000) + ('b' * 100))

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(get_calls.map { |call| call[:offset] }).to eq([0, 16_384])
    expect(outcomes[node1]).to be_success
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 20_000)
  end

  context 'with files that take several rounds on 2 nodes' do
    let(:contents) { { node1 => 'a' * 40_000, node2 => 'b' * 40_000 } }

    it 'keeps asking the node that is fine after the other failed in the first round' do
      stub_file_stats
      stub_get_replies do |args, name|
        next { data: 'not base64!', bytes: 5, size: 40_000 } if name == node2

        get_data(contents.fetch(name), args)
      end

      outcomes = client.download('/var/log/app.log', destination_dirs)

      expect(get_calls.map { |call| call[:identities] }).to eq([nodes, [node1], [node1]])
      expect(outcomes[node1]).to be_success
      expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 40_000)
      expect(outcomes[node2].error_kind).to eq(:transfer_failed)
    end
  end

  it 'passes over a later reply from a node of the batch whose size is covered and keeps its verified copy' do
    files = { node1 => 'a' * 40_000, node2 => 'b' * 100 }
    stub_file_stats(files)
    rpc.on(:get) do |args, names|
      get_calls << args.merge(identities: names)
      results = names.map { |name| rpc_result(name, get_data(files.fetch(name), args)) }
      results << rpc_result(node2, { data: encoded('x' * 100), bytes: 100, size: 100 }) unless names.include?(node2)
      results
    end

    outcomes = client.download('/var/log/app.log', destination_dirs)

    expect(get_calls.map { |call| call[:identities] }).to eq([nodes, [node1], [node1]])
    expect(outcomes.values).to all(be_success)
    expect(File.binread(File.join(dir_for(node2), 'app.log'))).to eq('b' * 100)
  end
end
