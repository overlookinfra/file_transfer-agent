# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Client, '#upload' do
  include_context 'with a file transfer client'

  let(:content) { SecureRandom.random_bytes(40_000) }
  let(:source) { local_file('source.bin', content) }
  let(:destination) { '/opt/app/source.bin' }

  before do
    stub_stat { |_args, names| results_for(names, { exists: false }) }
    stub_put
  end

  it 'sends the file in chunks of the chunk size under one token and verifies and renames it with the last one' do
    outcomes = client.upload(source, destination, nodes)

    expect(wrapper.published.length).to eq(3)
    expect(put_calls.map { |call| call[:offset] }).to eq([0, 16_384, 32_768])
    expect(put_calls.map { |call| decoded(call).bytesize }).to eq([16_384, 16_384, 7_232])
    expect(put_calls.map { |call| decoded(call) }.join).to eq(content)
    expect(put_calls.map { |call| call[:destination] }.uniq).to eq([destination])
    expect(put_calls.map { |call| call[:final] }).to eq([nil, nil, true])
    expect(put_calls.last).to include(sha256: Digest::SHA256.hexdigest(content), mode: '0644')
    tokens = put_calls.map { |call| call[:token] }.uniq
    expect(tokens.length).to eq(1)
    expect(tokens.first).to match(/\A[0-9a-f]{16}\z/)
    expect(outcomes.keys).to eq(nodes)
    expect(outcomes.values).to all(be_success)
    expect(outcomes.values.map(&:path)).to eq([destination, destination])
  end

  it 'sends no abort when every node finished the file' do
    client.upload(source, destination, nodes)

    expect(abort_calls).to be_empty
  end

  it 'addresses every request to the nodes and waits the rpc timeout for its replies and for publishing it' do
    client.upload(source, destination, nodes)

    expect(connection.calls.map { |call| call[:agent] }.uniq).to eq(['file_transfer'])
    expect(connection.calls.map { |call| call[:identities] }.uniq).to eq([nodes])
    expect(connection.calls.map { |call| [call[:timeout], call[:publish_timeout]] }.uniq).to eq([[200, 200]])
  end

  context 'with an upload batch size' do
    let(:client_options) { { upload_batch_size: 3 } }

    it 'publishes each chunk to that many nodes at once' do
      client.upload(source, destination, nodes)

      expect(put_calls.map { |call| call[:batch_size] }.uniq).to eq([3])
    end
  end

  it 'uploads into an existing directory on the nodes whose destination is one, every chunk once per landing path' do
    stub_stat do |_args, names|
      names.map { |name| rpc_result(name, { exists: true, type: name == node2 ? 'directory' : 'file' }) }
    end

    outcomes = client.upload(source, '/opt/app', nodes)

    expect(put_calls.length).to eq(6)
    expect(put_calls.map { |call| [call[:destination], call[:identities]] }.uniq).to contain_exactly(['/opt/app', [node1]], ['/opt/app/source.bin', [node2]])
    expect(put_calls.map { |call| call[:token] }.uniq.length).to eq(1)
    expect(outcomes[node1].path).to eq('/opt/app')
    expect(outcomes[node2].path).to eq('/opt/app/source.bin')
  end

  it 'fails a node where a destination that ends in a slash is not a directory, and sends it nothing' do
    stub_stat do |_args, names|
      names.map { |name| rpc_result(name, name == node2 ? { exists: true, type: 'directory' } : { exists: true, type: 'file' }) }
    end

    outcomes = client.upload(source, '/opt/app/', nodes)

    expect(put_calls.map { |call| call[:identities] }.uniq).to eq([[node2]])
    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to eq("/opt/app/ is not a directory on #{node1}")
    expect(outcomes[node2].path).to eq('/opt/app/source.bin')
  end

  it 'fails a node where a Windows destination that ends in a backslash does not exist, and sends it nothing' do
    stub_stat do |_args, names|
      names.map { |name| rpc_result(name, name == node2 ? { exists: true, type: 'directory' } : { exists: false }) }
    end

    outcomes = client.upload(source, 'C:\\app\\', nodes)

    expect(put_calls.map { |call| call[:identities] }.uniq).to eq([[node2]])
    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to eq("C:\\app\\ does not exist on #{node1}")
    expect(outcomes[node2]).to be_success
  end

  it 'sends a file whose name starts with a tilde under that name' do
    tilde = local_file('~notes.txt', 'n')
    stub_stat { |_args, names| results_for(names, { exists: true, type: 'directory' }) }

    outcomes = client.upload(tilde, '/opt/app', [node1])

    expect(put_calls.last).to include(destination: '/opt/app/~notes.txt')
    expect(outcomes[node1].path).to eq('/opt/app/~notes.txt')
  end

  it 'lands a directory given through a .. component under the name of the directory it stands for' do
    tree = File.join(workdir, 'tree')
    FileUtils.mkdir_p(File.join(tree, 'sub'))
    File.binwrite(File.join(tree, 'a.txt'), 'a')
    stub_stat { |_args, names| results_for(names, { exists: true, type: 'directory' }) }
    mkdirs = []
    rpc.on(:mkdir) do |args, names|
      mkdirs << args[:path]
      results_for(names)
    end

    outcomes = client.upload(File.join(tree, 'sub', '..'), '/opt/app', [node1])

    expect(mkdirs).to contain_exactly('/opt/app/tree', '/opt/app/tree/sub')
    expect(put_calls.last[:destination]).to eq('/opt/app/tree/a.txt')
    expect(outcomes[node1].path).to eq('/opt/app/tree')
  end

  it 'lands a directory given through a link under the link\'s own name' do
    real = File.join(workdir, 'real')
    FileUtils.mkdir_p(real)
    File.binwrite(File.join(real, 'a.txt'), 'a')
    link = File.join(workdir, 'link')
    File.symlink(real, link)
    stub_stat { |_args, names| results_for(names, { exists: true, type: 'directory' }) }
    mkdirs = []
    rpc.on(:mkdir) do |args, names|
      mkdirs << args[:path]
      results_for(names)
    end

    outcomes = client.upload(link, '/opt/app', [node1])

    expect(mkdirs).to eq(['/opt/app/link'])
    expect(put_calls.last[:destination]).to eq('/opt/app/link/a.txt')
    expect(outcomes[node1].path).to eq('/opt/app/link')
  end

  it 'fails every node for the root directory, which no directory can hold, before any call' do
    outcomes = client.upload('/', destination, nodes)

    expect(connection.calls).to be_empty
    expect(outcomes.values.map(&:kind).uniq).to eq([:transfer_failed])
    expect(outcomes[node1].message).to include('"/"', 'is not a plain file name')
  end

  it 'sends an empty file as one final chunk' do
    empty = local_file('empty.bin', '')

    outcomes = client.upload(empty, destination, [node1])

    expect(put_calls.length).to eq(1)
    expect(put_calls.first).to include(offset: 0, final: true, sha256: Digest::SHA256.hexdigest(''))
    expect(decoded(put_calls.first)).to eq('')
    expect(outcomes[node1]).to be_success
  end

  it 'drops a node whose chunk was refused, reports the message and still tells it to abort' do
    stub_put do |args, names|
      names.map do |name|
        next rpc_result(name, {}, statuscode: 1, statusmsg: 'No space left on device') if name == node2 && args[:offset] == 16_384

        rpc_result(name, {})
      end
    end

    outcomes = client.upload(source, destination, nodes)

    later = put_calls.select { |call| call[:offset] == 32_768 }
    expect(later.map { |call| call[:identities] }).to eq([[node1]])
    # The node's server answers status 1 itself for an agent it killed or
    # a request it refused, so the abort goes out whatever removed the file.
    expect(abort_calls.map { |call| call[:identities] }).to eq([[node2]])
    expect(outcomes[node2].kind).to eq(:transfer_failed)
    expect(outcomes[node2].message).to include('No space left on device')
    expect(outcomes[node1]).to be_success
  end

  # The agent answers a digest mismatch with status code 1 and the digest
  # it computed, and any other refusal of the final chunk without one.
  it 'reports a final chunk refused for another digest as checksum_mismatch and any other refusal as transfer_failed' do
    wrong_digest = 'f' * 64
    stub_put do |args, names|
      names.map do |name|
        next rpc_result(name, {}) unless args[:final]
        next rpc_result(name, {}, statuscode: 1, statusmsg: 'No space left on device') if name == node1

        rpc_result(name, { bytes: 7_232, size: 40_000, sha256: wrong_digest }, statuscode: 1,
          statusmsg: "Checksum mismatch for source.bin: expected #{args[:sha256]}, got #{wrong_digest}")
      end
    end

    outcomes = client.upload(source, destination, nodes)

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('No space left on device')
    expect(outcomes[node2].kind).to eq(:checksum_mismatch)
    expect(outcomes[node2].message).to include("The file_transfer.put #{destination} (final) call on #{node2} failed", "got #{wrong_digest}")
    expect(abort_calls.map { |call| call[:identities] }).to eq([nodes])
  end

  it 'reports a node that never answers, aborts on it and carries on with the rest' do
    stub_put { |_args, names| results_for(names - [node2]) }

    outcomes = client.upload(source, destination, nodes)

    expect(outcomes[node2].kind).to eq(:no_response)
    expect(outcomes[node2].message).to eq("No response from #{node2} for file_transfer.put #{destination} within 200 seconds. If the node is up, " \
                                          'its server may have stopped the agent at the DDL timeout of 120 seconds.')
    expect(outcomes[node1]).to be_success
    expect(abort_calls.map { |call| call.slice(:destination, :token, :identities) })
      .to eq([{ destination: destination, token: put_calls.first[:token], identities: [node2] }])
  end

  it 'aborts on the nodes that failed during a file and not on the rest, grouped by destination' do
    stub_stat do |_args, names|
      names.map { |name| rpc_result(name, { exists: true, type: name == node2 ? 'directory' : 'file' }) }
    end
    stub_put { |args, names| results_for(args[:final] ? names - [node2] : names) }

    outcomes = client.upload(source, '/opt/app', nodes)

    expect(outcomes[node1]).to be_success
    expect(outcomes[node2].kind).to eq(:no_response)
    expect(abort_calls.map { |call| call.slice(:destination, :token, :identities) })
      .to eq([{ destination: '/opt/app/source.bin', token: put_calls.first[:token], identities: [node2] }])
  end

  it 'aborts on the nodes still pending when the upload is interrupted' do
    stub_put do |args, names|
      raise Interrupt if args[:offset] == 16_384

      results_for(names)
    end

    expect { client.upload(source, destination, nodes) }.to raise_error(Interrupt)
    expect(abort_calls.map { |call| call[:identities] }).to eq([nodes])
  end

  it 'warns naming the temporary file when a node stays silent for its abort too' do
    stub_put { |args, names| results_for(args[:final] ? names - [node2] : names) }
    rpc.on(:abort) { |_args, names| results_for(names - [node2], { removed: true }) }

    outcomes = client.upload(source, destination, nodes)

    expect(outcomes[node2].kind).to eq(:no_response)
    expect(log.warnings).to include(a_string_including(".file_transfer-#{put_calls.first[:token]} beside #{destination} may remain on #{node2}", 'No response'))
  end

  it 'stops an upload whose source shrank underneath it and reports the node' do
    shrinking = local_file('shrinking.bin', SecureRandom.random_bytes(40_000))
    stub_put do |args, names|
      raise 'the client kept sending chunks of a file that had shrunk' if put_calls.length > 5

      File.truncate(shrinking, 16_384) if args[:offset].zero?
      results_for(names)
    end

    outcomes = client.upload(shrinking, destination, [node1])

    expect(put_calls.map { |call| call[:offset] }).to eq([0])
    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('shrank below the 40000 bytes')
    expect(abort_calls.map { |call| call[:identities] }).to eq([[node1]])
  end

  it 'stops at the size that it recorded when the source keeps growing and fails the nodes without a final chunk' do
    stub_put do |_args, names|
      File.open(source, 'ab') { |file| file.write('g' * 16_384) }
      results_for(names)
    end

    outcomes = client.upload(source, destination, nodes)

    # The third chunk reaches the recorded size, and the file is not at
    # its end there, so it is never sent.
    expect(put_calls.map { |call| call[:offset] }).to eq([0, 16_384])
    expect(put_calls.map { |call| call[:final] }).not_to include(true)
    expect(outcomes.values.map(&:message)).to all(include('changed while it was being uploaded'))
    expect(abort_calls.map { |call| call[:identities] }).to eq([nodes])
  end

  it 'sends a file whose size is a whole number of chunks with its last chunk as the final one' do
    exact = local_file('exact.bin', SecureRandom.random_bytes(32_768))

    outcomes = client.upload(exact, destination, [node1])

    expect(put_calls.map { |call| [call[:offset], decoded(call).bytesize, call[:final]] }).to eq([[0, 16_384, nil], [16_384, 16_384, true]])
    expect(outcomes[node1]).to be_success
  end

  # A process without a locale hands over its paths tagged as plain bytes.
  context 'with a source file tagged as plain bytes' do
    it 'sends a name that is valid UTF-8 as UTF-8, as the last component of the destination' do
      accented = local_file('café.bin', 'au lait').dup.force_encoding(Encoding::BINARY)
      stub_stat { |_args, names| results_for(names, { exists: true, type: 'directory' }) }

      outcomes = client.upload(accented, '/opt/app', [node1])

      landed = put_calls.last[:destination]
      expect(landed).to eq('/opt/app/café.bin')
      expect(landed.encoding).to eq(Encoding::UTF_8)
      expect(outcomes[node1]).to be_success
    end

    it 'raises for a name that is not valid UTF-8, before any call' do
      unnameable = File.join(workdir, "caf\xE9.bin".b)
      begin
        File.binwrite(unnameable, 'latin')
      rescue SystemCallError
        skip('needs a filesystem that takes any bytes in a name')
      end

      expect { client.upload(unnameable.force_encoding(Encoding::BINARY), destination, nodes) }.to raise_error(ArgumentError) do |error|
        expect(error.message).to include('caf\xE9.bin', 'is not valid UTF-8')
      end
      expect(connection.calls).to be_empty
    end
  end

  it 'sends to a destination tagged as plain bytes as UTF-8' do
    outcomes = client.upload(source, '/srv/café/app.bin'.b, [node1])

    stat_call = rpc.calls.first
    expect(stat_call.first).to eq(:stat)
    expect(stat_call[1][:path]).to eq('/srv/café/app.bin')
    expect(stat_call[1][:path].encoding).to eq(Encoding::UTF_8)
    expect(outcomes[node1].path).to eq('/srv/café/app.bin')
  end

  it 'raises for a destination that is not valid UTF-8, before any call' do
    expect { client.upload(source, "/srv/caf\xE9/app.bin".b, nodes) }.to raise_error(ArgumentError) do |error|
      expect(error.message).to include('caf\xE9', 'is not valid UTF-8')
    end
    expect(connection.calls).to be_empty
  end

  it 'fails every node for a file whose name is not a plain file name, before any call' do
    odd = local_file("Icon\r", 'icon')

    outcomes = client.upload(odd, destination, nodes)

    expect(connection.calls).to be_empty
    expect(outcomes.values.map(&:kind).uniq).to eq([:transfer_failed])
    expect(outcomes[node1].message).to include('"Icon\r"', 'is not a plain file name')
  end

  it 'fails every node for a tree entry whose name is not a plain file name and sends nothing of it' do
    stub_mkdir
    tree = File.join(workdir, 'tree')
    Dir.mkdir(tree)
    File.write(File.join(tree, "Icon\r"), 'icon')
    File.write(File.join(tree, 'readme.txt'), 'plain')

    outcomes = client.upload(tree, destination, nodes)

    expect(put_calls).to be_empty
    expect(outcomes.values.map(&:kind).uniq).to eq([:transfer_failed])
    expect(outcomes[node1].message).to include('Icon\r', 'is not a plain file name')
  end

  it 'raises for a source that does not exist, before any call to the nodes' do
    expect { client.upload(File.join(workdir, 'missing.bin'), destination, nodes) }.to raise_error(Errno::ENOENT)
    expect(connection.calls).to be_empty
  end

  it 'raises for a source that is a dangling link, before any call to the nodes' do
    dangling = File.join(workdir, 'dangling.bin')
    File.symlink(File.join(workdir, 'gone.bin'), dangling)

    expect { client.upload(dangling, destination, nodes) }.to raise_error(Errno::ENOENT)
    expect(connection.calls).to be_empty
  end

  it 'fails every node and sends nothing when the source cannot be opened' do
    allow(File).to receive(:open).and_wrap_original do |original, path, *args, &block|
      raise Errno::EACCES, path if path == source

      original.call(path, *args, &block)
    end

    outcomes = client.upload(source, destination, nodes)

    expect(put_calls).to be_empty
    expect(abort_calls).to be_empty
    expect(outcomes.values.map(&:kind).uniq).to eq([:transfer_failed])
    expect(outcomes[node1].message).to include("Reading #{source} failed", 'Errno::EACCES')
  end

  it 'fails every node and aborts on them when a later read of the source fails' do
    allow(File).to receive(:open).and_wrap_original do |original, path, *args, &block|
      next original.call(path, *args, &block) unless path == source

      original.call(path, *args) do |file|
        reads = 0
        allow(file).to receive(:read).and_wrap_original do |read, *read_args|
          reads += 1
          raise Errno::EIO, path if reads == 2

          read.call(*read_args)
        end
        block.call(file)
      end
    end

    outcomes = client.upload(source, destination, nodes)

    expect(put_calls.map { |call| call[:offset] }).to eq([0])
    expect(outcomes.values.map(&:kind).uniq).to eq([:transfer_failed])
    expect(outcomes[node1].message).to include("Reading #{source} failed", 'Errno::EIO')
    expect(abort_calls.map { |call| call[:identities] }).to eq([nodes])
  end

  it 'fails every node for a source that is a named pipe, without opening it' do
    pipe = File.join(workdir, 'pipe')
    File.mkfifo(pipe, 0o600)

    outcomes = Timeout.timeout(10) { client.upload(pipe, destination, nodes) }

    expect(put_calls).to be_empty
    expect(outcomes.values.map(&:kind)).to eq([:transfer_failed, :transfer_failed])
    expect(outcomes[node1].message).to eq("#{pipe} is not a regular file")
  end

  it 'reports every node when none of them can be stat-ed and sends nothing' do
    stub_stat { |_args, names| results_for(names, {}, statuscode: 4, statusmsg: 'The path input must be an absolute path') }

    outcomes = client.upload(source, destination, nodes)

    expect(put_calls).to be_empty
    expect(outcomes.values.map(&:kind)).to eq([:rpc_error, :rpc_error])
    expect(outcomes.values.map(&:message)).to all(include('The path input must be an absolute path'))
  end

  it 'fails the nodes when the source grows while it is being sent, sends no final chunk and aborts' do
    stub_put do |args, names|
      File.open(source, 'ab') { |file| file.write('and more') } if args[:offset].zero?
      results_for(names)
    end

    outcomes = client.upload(source, destination, nodes)

    expect(outcomes.values.map(&:kind)).to eq([:transfer_failed, :transfer_failed])
    expect(outcomes.values.map(&:message)).to all(include('changed while it was being uploaded'))
    expect(put_calls.map { |call| call[:final] }).not_to include(true)
    expect(abort_calls.map { |call| call[:identities] }).to eq([nodes])
  end

  it 'fails the nodes when the source is rewritten at the same size while it is being sent and sends no final chunk' do
    stub_put do |args, names|
      File.utime(Time.at(1_600_000_000), Time.at(1_600_000_000), source) if args[:offset].zero?
      results_for(names)
    end

    outcomes = client.upload(source, destination, nodes)

    expect(outcomes.values.map(&:kind)).to eq([:transfer_failed, :transfer_failed])
    expect(outcomes.values.map(&:message)).to all(include('changed while it was being uploaded'))
    expect(put_calls.map { |call| call[:final] }).not_to include(true)
  end

  context 'when a chunk weighs more than the broker limit' do
    before { stub_const('MCollective::Util::FileTransfer::Rpc::MAX_PAYLOAD', 30_000) }

    it 'fails every node before the chunk leaves the client and names the message data size as the remedy' do
      outcomes = client.upload(source, destination, nodes)

      expect(put_calls.map { |call| decoded(call).bytesize }).to eq([16_384])
      expect(wrapper.published).to be_empty
      expect(outcomes.values.map(&:kind).uniq).to eq([:payload_too_large])
      expect(outcomes[node1].message).to include("exceeds the broker's 30000 byte payload limit", 'Lower the message data size')
    end
  end

  context 'when the broker cannot be reached' do
    it 'fails every node with rpc_failed and raises nothing' do
      allow(connection).to receive(:with_client).and_raise(RuntimeError, 'nats: connection refused')

      outcomes = client.upload(source, destination, nodes)

      expect(outcomes.values.map(&:kind).uniq).to eq([:rpc_failed])
      expect(outcomes[node1].message).to include('nats: connection refused')
      expect(log.debugs).not_to include(a_string_including('nodes per request'))
    end
  end

  context 'when every node stays silent for a chunk' do
    it 'reports them as not responding' do
      stub_put { |_args, _names| [] }

      outcomes = client.upload(source, destination, nodes)

      expect(put_calls.length).to eq(1)
      expect(outcomes.values.map(&:kind).uniq).to eq([:no_response])
    end
  end

  context 'when the destination is a directory on some nodes only' do
    before do
      stub_stat do |_args, names|
        names.map { |name| rpc_result(name, { exists: true, type: name == node2 ? 'directory' : 'file' }) }
      end
    end

    context 'when the broker refuses the second landing group' do
      before { stub_const('MCollective::Util::FileTransfer::Rpc::MAX_PAYLOAD', 200_000) }

      # Only the longer destination trips the guard.
      def wire_size(args)
        super + (args[:destination] == '/opt/app/source.bin' ? 1_000_000 : 0)
      end

      it 'keeps the group whose chunk already landed, fails only the refused one and tells it to abort' do
        outcomes = client.upload(source, '/opt/app', nodes)

        expect(outcomes[node1]).to be_success
        expect(outcomes[node2].kind).to eq(:payload_too_large)
        expect(abort_calls.map { |call| call[:identities] }).to eq([[node2]])
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
      expect(finals.map { |call| [call[:destination], decoded(call)] }).to contain_exactly(
        ['/opt/app/tree/top.txt', 'top'],
        ['/opt/app/tree/sub/inner.txt', 'inner']
      )
      expect(finals.map { |call| call[:token] }.uniq.length).to eq(2)
      expect(outcomes[node1]).to be_success
      expect(outcomes[node1].path).to eq('/opt/app/tree')
    end

    it 'sends nothing more to a node after its first failure in the tree and finishes the rest' do
      FileUtils.mkdir_p(File.join(tree, 'sub'))
      File.binwrite(File.join(tree, 'a.txt'), 'a')
      File.binwrite(File.join(tree, 'sub', 'b.txt'), 'b')
      mkdirs = []
      rpc.on(:mkdir) do |args, names|
        mkdirs << [args[:path], names]
        names.map do |name|
          next rpc_result(name, {}, statuscode: 1, statusmsg: 'Read-only file system') if name == node2

          rpc_result(name, {})
        end
      end

      outcomes = client.upload(tree, '/opt/app/tree', nodes)

      expect(mkdirs).to eq([['/opt/app/tree', nodes], ['/opt/app/tree/sub', [node1]]])
      expect(put_calls.map { |call| call[:identities] }.uniq).to eq([[node1]])
      expect(outcomes[node1]).to be_success
      expect(outcomes[node2].kind).to eq(:transfer_failed)
      expect(outcomes[node2].message).to include('Read-only file system')
    end

    it 'keeps the failure a node had when a later entry cannot be read' do
      FileUtils.mkdir_p(tree)
      File.binwrite(File.join(tree, 'a.txt'), 'a')
      File.symlink('/nonexistent/target', File.join(tree, 'broken'))
      stub_put do |args, names|
        names.map do |name|
          next rpc_result(name, {}, statuscode: 1, statusmsg: 'No space left on device') if name == node2 && args[:final]

          rpc_result(name, {})
        end
      end

      outcomes = client.upload(tree, '/opt/app/tree', nodes)

      expect(outcomes[node2].message).to include('No space left on device')
      expect(outcomes[node1].message).to include('Reading', 'Errno::ENOENT')
    end

    it 'keeps the failure a node had when a later entry cannot be named' do
      FileUtils.mkdir_p(tree)
      File.binwrite(File.join(tree, 'a.txt'), 'a')
      File.binwrite(File.join(tree, "zz\r"), 'late')
      stub_put do |args, names|
        names.map do |name|
          next rpc_result(name, {}, statuscode: 1, statusmsg: 'No space left on device') if name == node2 && args[:final]

          rpc_result(name, {})
        end
      end

      outcomes = client.upload(tree, '/opt/app/tree', nodes)

      expect(outcomes[node2].message).to include('No space left on device')
      expect(outcomes[node1].message).to include('zz\r', 'is not a plain file name')
    end

    it 'skips a link to a directory with a warning and sends the directory itself' do
      FileUtils.mkdir_p(File.join(tree, 'sub'))
      File.binwrite(File.join(tree, 'sub', 'a.txt'), 'a')
      File.symlink(File.join(tree, 'sub'), File.join(tree, 'link'))

      outcomes = client.upload(tree, '/opt/app/tree', [node1])

      expect(put_calls.select { |call| call[:final] }.map { |call| call[:destination] }).to eq(['/opt/app/tree/sub/a.txt'])
      expect(log.warnings).to include("Skipping #{File.join(tree, 'link')}, a symbolic link to a directory")
      expect(outcomes[node1]).to be_success
    end

    it 'sends a link to a file as the file it points at' do
      FileUtils.mkdir_p(tree)
      File.binwrite(File.join(tree, 'real.txt'), 'real')
      File.symlink(File.join(tree, 'real.txt'), File.join(tree, 'alias.txt'))

      outcomes = client.upload(tree, '/opt/app/tree', [node1])

      finals = put_calls.select { |call| call[:final] }
      expect(finals.map { |call| [call[:destination], decoded(call)] }).to contain_exactly(['/opt/app/tree/alias.txt', 'real'], ['/opt/app/tree/real.txt', 'real'])
      expect(outcomes[node1]).to be_success
    end

    it 'fails the node when the tree holds a named pipe, without opening it' do
      FileUtils.mkdir_p(tree)
      File.mkfifo(File.join(tree, 'pipe'), 0o600)

      outcomes = Timeout.timeout(10) { client.upload(tree, '/opt/app/tree', [node1]) }

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include(File.join('tree', 'pipe'), 'is not a regular file')
    end

    # A process without a locale hands over its paths tagged as plain bytes.
    context 'with a source tagged as plain bytes' do
      let(:untagged) { tree.dup.force_encoding(Encoding::BINARY) }

      before { FileUtils.mkdir_p(tree) }

      it 'sends a name that is valid UTF-8 as UTF-8' do
        File.binwrite(File.join(tree, 'café.txt'), 'au lait')

        outcomes = client.upload(untagged, '/opt/app/tree', [node1])

        landed = put_calls.last[:destination]
        expect(landed).to eq('/opt/app/tree/café.txt')
        expect(landed.encoding).to eq(Encoding::UTF_8)
        expect(outcomes[node1]).to be_success
      end

      it 'fails the node for an entry whose name is not valid UTF-8, naming the entry' do
        begin
          File.binwrite(File.join(tree, "caf\xE9.txt".b), 'latin')
        rescue SystemCallError
          skip('needs a filesystem that takes any bytes in a name')
        end

        outcomes = client.upload(untagged, '/opt/app/tree', [node1])

        expect(put_calls).to be_empty
        expect(outcomes[node1].kind).to eq(:transfer_failed)
        expect(outcomes[node1].message).to include('caf\xE9.txt', 'is not valid UTF-8')
      end
    end

    it 'makes a destination that ends in a slash and does not exist yet' do
      FileUtils.mkdir_p(tree)
      File.binwrite(File.join(tree, 'a.txt'), 'a')
      mkdirs = []
      rpc.on(:mkdir) do |args, names|
        mkdirs << args[:path]
        results_for(names)
      end

      outcomes = client.upload(tree, '/opt/app/tree/', [node1])

      expect(mkdirs).to eq(['/opt/app/tree/'])
      expect(put_calls.select { |call| call[:final] }.map { |call| call[:destination] }).to eq(['/opt/app/tree/a.txt'])
      expect(outcomes[node1]).to be_success
    end

    it 'creates the tree at the landing path of each node when the destination is a directory on one node only' do
      FileUtils.mkdir_p(File.join(tree, 'sub'))
      File.binwrite(File.join(tree, 'sub', 'a.txt'), 'a')
      stub_stat do |_args, names|
        names.map { |name| rpc_result(name, name == node2 ? { exists: true, type: 'directory' } : { exists: false }) }
      end
      mkdirs = []
      rpc.on(:mkdir) do |args, names|
        mkdirs << [args[:path], names]
        results_for(names)
      end

      outcomes = client.upload(tree, '/opt/app', nodes)

      expect(mkdirs).to contain_exactly(['/opt/app', [node1]], ['/opt/app/tree', [node2]],
        ['/opt/app/sub', [node1]], ['/opt/app/tree/sub', [node2]])
      expect(outcomes[node1].path).to eq('/opt/app')
      expect(outcomes[node2].path).to eq('/opt/app/tree')
    end
  end
end
