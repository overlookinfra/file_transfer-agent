# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Client, '#upload' do
  include_context 'with a file transfer client'

  let(:content) { SecureRandom.random_bytes(40_000) }
  let(:source) { local_file('source.bin', content) }
  let(:destination) { '/opt/app/source.bin' }

  before do
    stub_session
    stub_stat { |_args, names| results_for(names, { exists: false }) }
    stub_put
  end

  it 'sends the file in chunks of the chunk size and verifies and moves it with the last one' do
    outcomes = client.upload(source, destination, nodes)

    expect(wrapper.published.length).to eq(3)
    expect(chunks.map { |call| call[:offset] }).to eq([0, 16_384, 32_768])
    expect(chunks.map { |call| decoded(call).bytesize }).to eq([16_384, 16_384, 7_232])
    expect(chunks.map { |call| decoded(call) }.join).to eq(content)
    expect(chunks.map { |call| call[:name] }.uniq).to eq(['source.bin'])
    expect(chunks.map { |call| call[:final] }).to eq([nil, nil, true])
    expect(chunks.last).to include(sha256: Digest::SHA256.hexdigest(content), destination: destination, mode: '0644')
    expect(chunks.map { |call| call[:session] }.uniq.length).to eq(1)
    expect(outcomes.keys).to eq(nodes)
    expect(outcomes.values).to all(be_success)
    expect(outcomes.values.map(&:path)).to eq([destination, destination])
  end

  it 'creates one session for the transfer and cleans it up afterwards on every node' do
    sessions = []
    rpc.on(:cleanup) do |args, names|
      sessions << [args[:session], names]
      results_for(names, { removed: true })
    end

    client.upload(source, destination, nodes)

    expect(sessions).to eq([[chunks.first[:session], nodes]])
    expect(chunks.first[:session]).to match(/\A[0-9a-f-]{36}\z/)
  end

  it 'addresses every request to the nodes and allows the rpc timeout for publishing it' do
    client.upload(source, destination, nodes)

    expect(connection.calls.map { |call| call[:agent] }.uniq).to eq(['file_transfer'])
    expect(connection.calls.map { |call| call[:identities] }.uniq).to eq([nodes])
    expect(connection.calls.map { |call| call[:publish_timeout] }.uniq).to eq([30])
  end

  it 'uploads into an existing directory on the nodes whose destination is one' do
    stub_stat do |_args, names|
      names.map { |name| rpc_result(name, { exists: true, type: name == node2 ? 'directory' : 'file' }) }
    end

    outcomes = client.upload(source, '/opt/app', nodes)

    finals = put_calls.select { |call| call[:final] }
    expect(finals.map { |call| [call[:destination], call[:identities]] }).to contain_exactly(['/opt/app', [node1]], ['/opt/app/source.bin', [node2]])
    expect(outcomes[node1].path).to eq('/opt/app')
    expect(outcomes[node2].path).to eq('/opt/app/source.bin')
  end

  it 'sends an empty file as one final chunk' do
    empty = local_file('empty.bin', '')

    outcomes = client.upload(empty, destination, [node1])

    expect(chunks.length).to eq(1)
    expect(chunks.first).to include(offset: 0, final: true, sha256: Digest::SHA256.hexdigest(''))
    expect(decoded(chunks.first)).to eq('')
    expect(outcomes[node1]).to be_success
  end

  it 'drops a node whose chunk the agent refused and reports the agent message' do
    stub_put do |args, names|
      names.map do |name|
        next rpc_result(name, {}, statuscode: 1, statusmsg: 'No space left on device') if name == node2 && args[:offset] == 16_384

        rpc_result(name, {})
      end
    end

    outcomes = client.upload(source, destination, nodes)

    later = put_calls.select { |call| call[:offset] == 32_768 }
    expect(later.map { |call| call[:identities] }).to eq([[node1]])
    expect(outcomes[node2].kind).to eq(:transfer_failed)
    expect(outcomes[node2].message).to include('No space left on device')
    expect(outcomes[node1]).to be_success
  end

  it 'reports a node that never answers and carries on with the rest' do
    stub_put { |_args, names| results_for(names - [node2]) }

    outcomes = client.upload(source, destination, nodes)

    expect(outcomes[node2].kind).to eq(:no_response)
    expect(outcomes[node1]).to be_success
  end

  context 'when the cleanup option is off for one node' do
    let(:client_options) { { cleanup: { node2 => false } } }

    it 'leaves the session in place on that node and warns' do
      cleaned = []
      rpc.on(:cleanup) do |_args, names|
        cleaned << names
        results_for(names, { removed: true })
      end

      client.upload(source, destination, nodes)

      expect(cleaned).to eq([[node1]])
      expect(log.warnings).to include(a_string_including('Leaving session', node2))
    end
  end

  context 'when the cleanup option is off for every node' do
    let(:client_options) { { cleanup: false } }

    it 'removes no session' do
      cleaned = []
      rpc.on(:cleanup) do |_args, names|
        cleaned << names
        results_for(names, { removed: true })
      end

      client.upload(source, destination, nodes)

      expect(cleaned).to be_empty
      expect(log.warnings.grep(/Leaving session/).length).to eq(2)
    end
  end

  it 'stops an upload whose source shrank underneath it and reports the node' do
    shrinking = local_file('shrinking.bin', SecureRandom.random_bytes(40_000))
    stub_put do |args, names|
      File.truncate(shrinking, 16_384) if args[:offset].zero?
      results_for(names)
    end

    outcomes = client.upload(shrinking, destination, [node1])

    expect(chunks.map { |call| call[:offset] }).to eq([0])
    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('shrank below the 40000 bytes')
  end

  it 'reports every node when none of them can be stat-ed and creates no session' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 4, statusmsg: 'The path input must be an absolute path') }

    outcomes = client.upload(source, destination, nodes)

    expect(rpc.calls.map(&:first)).not_to include(:mktemp)
    expect(outcomes.values.map(&:kind)).to eq([:rpc_error, :rpc_error])
    expect(outcomes.values.map(&:message)).to all(include('The path input must be an absolute path'))
  end

  it 'reports every node when none of them can make a session and sends no chunks' do
    rpc.on(:mktemp) { |_args, names| results_for(names, {}, statuscode: 1, statusmsg: 'No space left on device') }

    outcomes = client.upload(source, destination, nodes)

    expect(chunks).to be_empty
    expect(outcomes.values.map(&:kind)).to eq([:transfer_failed, :transfer_failed])
    expect(outcomes.values.map(&:message)).to all(include('No space left on device'))
  end

  context 'when the rpc timeout is below the chunk timeout floor' do
    let(:client_options) { { rpc_timeout: 3 } }

    it 'sends a multi chunk file with the rpc timeout as every timeout' do
      outcomes = client.upload(source, destination, [node1])

      expect(chunks.map { |call| call[:offset] }).to eq([0, 16_384, 32_768])
      expect(connection.calls.map { |call| call[:timeout] }.uniq).to eq([3])
      expect(outcomes[node1]).to be_success
    end
  end

  it 'still cleans up when the session was created and a later step raised' do
    allow(MCollective::Util::FileTransfer::Upload).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |upload| allow(upload).to receive(:upload_file).and_raise(RuntimeError, 'boom') }
    end
    cleaned = false
    rpc.on(:cleanup) do |_args, names|
      cleaned = true
      results_for(names, { removed: true })
    end

    expect { client.upload(source, destination, [node1]) }.to raise_error(RuntimeError, 'boom')
    expect(cleaned).to be(true)
  end

  it 'reports the node whose mktemp named no path but still asks it to clean up, without the stale warning' do
    rpc.on(:mktemp) { |_args, names| results_for(names, { path: nil, swept: 0 }) }
    cleaned = []
    rpc.on(:cleanup) do |_args, names|
      cleaned << names
      results_for(names, { removed: false })
    end
    small = local_file('small.bin', 'x' * 100)

    outcomes = client.upload(small, destination, [node1])

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('without a session path')
    expect(cleaned).to eq([[node1]])
    expect(log.warnings).not_to include(a_string_including('stale_after'))
  end

  context 'when the broker limit leaves no room for a chunk' do
    let(:max_payload) { 30_000 }

    it 'fails every node before anything is sent' do
      outcomes = client.upload(source, destination, nodes)

      expect(outcomes.values.map(&:kind).uniq).to eq([:payload_too_large])
      expect(outcomes[node1].message).to include('payload limit of 30000 bytes leaves less than 16384 bytes')
      expect(rpc.calls).to be_empty
    end
  end

  context 'when the broker limit refuses a chunk' do
    let(:max_payload) { 200_000 }
    let(:chunk_size) { 100_000 }

    # Above 60 KB of content the fake wire grows by an unmodeled 150 KB.
    def wire_size(args)
      super + (decoded(args).bytesize > 60_000 ? 150_000 : 0)
    end

    it 'fails the node before the chunk leaves the client and names the chunk size as the remedy' do
      big = local_file('big.bin', SecureRandom.random_bytes(70_000))

      outcomes = client.upload(big, destination, [node1])

      expect(chunks.map { |call| decoded(call).bytesize }).to eq([70_000])
      expect(wrapper.published).to be_empty
      expect(outcomes[node1].kind).to eq(:payload_too_large)
      expect(outcomes[node1].message).to include("exceeds the broker's 200000 byte payload limit", 'Lower the chunk size')
    end
  end

  context 'when every node stays silent for a chunk' do
    it 'reports them as not responding' do
      stub_put { |_args, _names| [] }

      outcomes = client.upload(source, destination, nodes)

      expect(chunks.length).to eq(1)
      expect(outcomes.values.map(&:kind).uniq).to eq([:no_response])
    end
  end

  context 'when the NATS wrapper is not reachable' do
    let(:connection) { FakeConnection.new(nil) }

    it 'sizes chunks from the default limit and warns that the limit and the guard are missing' do
      outcomes = client.upload(source, destination, [node1])

      expect(log.once_ids.uniq).to contain_exactly('file_transfer_max_payload_unknown', 'file_transfer_guard_unavailable')
      expect(log.once_messages.first).to include('NoMethodError')
      expect(outcomes[node1]).to be_success
      expect(chunks.map { |call| decoded(call).bytesize }).to eq([16_384, 16_384, 7_232])
    end
  end

  context 'when the destination is a directory on some nodes only' do
    before do
      stub_stat do |_args, names|
        names.map { |name| rpc_result(name, { exists: true, type: name == node2 ? 'directory' : 'file' }) }
      end
    end

    context 'and the broker refuses the second landing group' do
      let(:max_payload) { 200_000 }

      # Only the longer destination trips the guard.
      def wire_size(args)
        super + (args[:destination] == '/opt/app/source.bin' ? 1_000_000 : 0)
      end

      it 'keeps the group whose chunk already landed and fails only the refused one' do
        outcomes = client.upload(source, '/opt/app', nodes)

        expect(outcomes[node1]).to be_success
        expect(outcomes[node2].kind).to eq(:payload_too_large)
      end
    end
  end

  context 'with a directory' do
    let(:tree) { File.join(workdir, 'tree') }

    before { stub_mkdir }

    it 'creates each directory with its mode and uploads every file under its relative name' do
      FileUtils.mkdir_p(File.join(tree, 'sub'))
      File.chmod(0o750, File.join(tree, 'sub'))
      File.binwrite(File.join(tree, 'top.txt'), 'top')
      File.binwrite(File.join(tree, 'sub', 'inner.txt'), 'inner')
      mkdirs = []
      rpc.on(:mkdir) do |args, names|
        mkdirs << args
        results_for(names)
      end

      outcomes = client.upload(tree, '/opt/app/tree', [node1])

      expect(mkdirs).to contain_exactly({ path: '/opt/app/tree', mode: '0755' }, { path: '/opt/app/tree/sub', mode: '0750' })
      finals = put_calls.select { |call| call[:final] }
      expect(finals.map { |call| [call[:name], call[:destination], decoded(call)] }).to contain_exactly(
        ['top.txt', '/opt/app/tree/top.txt', 'top'],
        ['sub/inner.txt', '/opt/app/tree/sub/inner.txt', 'inner']
      )
      expect(outcomes[node1]).to be_success
      expect(outcomes[node1].path).to eq('/opt/app/tree')
    end

    it 'skips a link to a directory with a warning and sends the directory itself' do
      FileUtils.mkdir_p(File.join(tree, 'sub'))
      File.binwrite(File.join(tree, 'sub', 'a.txt'), 'a')
      File.symlink(File.join(tree, 'sub'), File.join(tree, 'link'))

      outcomes = client.upload(tree, '/opt/app/tree', [node1])

      expect(put_calls.select { |call| call[:final] }.map { |call| call[:name] }).to eq(['sub/a.txt'])
      expect(log.warnings).to include("Skipping #{File.join(tree, 'link')}, a symbolic link to a directory")
      expect(outcomes[node1]).to be_success
    end

    it 'sends a link to a file as the file it points at' do
      FileUtils.mkdir_p(tree)
      File.binwrite(File.join(tree, 'real.txt'), 'real')
      File.symlink(File.join(tree, 'real.txt'), File.join(tree, 'alias.txt'))

      outcomes = client.upload(tree, '/opt/app/tree', [node1])

      finals = put_calls.select { |call| call[:final] }
      expect(finals.map { |call| [call[:name], decoded(call)] }).to contain_exactly(['alias.txt', 'real'], ['real.txt', 'real'])
      expect(outcomes[node1]).to be_success
    end

    it 'stops a link that points back up its own branch' do
      FileUtils.mkdir_p(File.join(tree, 'sub'))
      File.binwrite(File.join(tree, 'sub', 'a.txt'), 'a')
      File.symlink(tree, File.join(tree, 'sub', 'back'))

      outcomes = client.upload(tree, '/opt/app/tree', [node1])

      expect(put_calls.select { |call| call[:final] }.map { |call| call[:name] }).to eq(['sub/a.txt'])
      expect(outcomes[node1]).to be_success
    end

    it 'reports a local entry it cannot read rather than raising' do
      FileUtils.mkdir_p(tree)
      File.binwrite(File.join(tree, 'a.txt'), 'a')
      File.symlink('/nonexistent/target', File.join(tree, 'broken'))

      outcomes = client.upload(tree, '/opt/app/tree', [node1])

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('Reading')
    end
  end
end
