# frozen_string_literal: true

require 'spec_helper'

# A download end to end: the stat of the source, the placement of each
# verified copy, the listing of a tree and its local side. The get rounds
# are in receiver_spec.rb.
RSpec.describe MCollective::Util::FileTransfer::Client, '#download' do
  include_context 'with a download client'

  it 'downloads the file from every node and places each verified copy under its node directory' do
    stub_file_stats
    stub_get

    outcomes = client.download('/var/log/app.log', destination_dirs)

    expect(outcomes.keys).to eq(nodes)
    expect(outcomes.values).to all(be_success)
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 12_000)
    expect(File.binread(File.join(dir_for(node2), 'app.log'))).to eq('b' * 100)
    expect(outcomes[node1].path).to eq(File.join(dir_for(node1), 'app.log'))
  end

  it 'waits the rpc timeout for the stat and for each get, and names the DDL timeout too for a node that stays silent' do
    stub_stat { |_args, names| results_for(names - [node2], { exists: true, type: 'file', size: 3, mode: '0644', sha256: Digest::SHA256.hexdigest('abc') }) }
    stub_get { |_path, _name| 'abc' }

    outcomes = client.download('/var/log/app.log', destination_dirs)

    expect(connection.calls.map { |call| call[:timeout] }.uniq).to eq([200])
    expect(outcomes[node1]).to be_success
    expect(outcomes[node2].kind).to eq(:no_response)
    expect(outcomes[node2].message).to include("No response from #{node2} for file_transfer.stat /var/log/app.log within 200 seconds",
      'stopped the agent at the DDL timeout of 120 seconds')
  end

  it 'makes one stat and one get for a file that fits a reply' do
    stub_file_stats
    stub_get

    client.download('/var/log/app.log', destination_dirs)

    expect(rpc.calls.map(&:first)).to eq([:stat, :get])
  end

  # A process without a locale hands over its paths tagged as plain bytes.
  it 'reads a source and destination directories tagged as plain bytes as UTF-8' do
    stub_file_stats
    stub_get
    accented = destination_dirs.transform_values { |directory| File.join(directory, 'café').b }

    outcomes = client.download('/var/log/café.log'.b, accented)

    path = get_calls.first[:path]
    expect(path).to eq('/var/log/café.log')
    expect(path.encoding).to eq(Encoding::UTF_8)
    expect(outcomes.values).to all(be_success)
    expect(File.binread(File.join(dir_for(node1), 'café', 'café.log'))).to eq('a' * 12_000)
  end

  it 'raises for a destination directory that is not valid UTF-8, before any call' do
    invalid = destination_dirs.merge(node2 => "#{dir_for(node2)}/caf\xE9".b)

    expect { client.download('/var/log/app.log', invalid) }.to raise_error(ArgumentError) do |error|
      expect(error.message).to include('caf\xE9', node2, 'is not valid UTF-8')
    end
    expect(connection.calls).to be_empty
  end

  it 'leaves nothing beside the destination when the rename into place is interrupted' do
    stub_file_stats
    stub_get
    beside = nil
    allow(File).to receive(:rename).and_wrap_original do |original, from, to|
      if File.basename(from).start_with?('.file_transfer-')
        beside = from
        raise Interrupt
      end

      original.call(from, to)
    end

    expect { client.download('/var/log/app.log', destination_dirs) }.to raise_error(Interrupt)
    expect(beside).not_to be_nil
    expect(File.exist?(beside)).to be(false)
    expect(Dir.children(File.dirname(beside))).to be_empty
  end

  it 'places a download of a Windows path under its last component' do
    stub_file_stats
    stub_get

    outcomes = client.download('C:\\logs\\app.log', destination_dirs)

    expect(outcomes.values).to all(be_success)
    expect(get_calls.map { |call| call[:path] }.uniq).to eq(['C:\\logs\\app.log'])
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 12_000)
  end

  it 'places a tree downloaded from a Windows path under its last component' do
    stub_directory_stats
    rpc.on(:list) { |_args, names| results_for(names, { entries: [file_entry('one.txt', 'one')] }) }
    stub_get { |_path, _name| 'one' }

    outcomes = client.download('C:\\srv\\data', destination_dirs.slice(node1))

    expect(outcomes[node1].path).to eq(File.join(dir_for(node1), 'data'))
    expect(File.read(File.join(dir_for(node1), 'data', 'one.txt'))).to eq('one')
  end

  it 'assembles each copy beside its destination at 0600 under a temporary name, and places it once verified' do
    stub_file_stats
    seen = []
    stub_get do |_path, name|
      seen |= Dir.children(dir_for(name)).map { |child| [child, File.stat(File.join(dir_for(name), child)).mode & 0o777] }
      contents.fetch(name)
    end

    client.download('/var/log/app.log', destination_dirs)

    expect(seen.length).to eq(2)
    expect(seen.map(&:first)).to all(start_with('.file_transfer-'))
    expect(seen.map(&:last).uniq).to eq([0o600])
    expect(Dir.children(dir_for(node1))).to eq(['app.log'])
    expect(Dir.children(dir_for(node2))).to eq(['app.log'])
  end

  it 'fails every node with rpc_failed and raises nothing when the broker cannot be reached' do
    allow(connection).to receive(:with_client).and_raise(RuntimeError, 'nats: connection refused')

    outcomes = client.download('/var/log/app.log', destination_dirs)

    expect(outcomes.values.map(&:kind).uniq).to eq([:rpc_failed])
    expect(outcomes[node1].message).to include('nats: connection refused')
  end

  context 'with more nodes than a download round takes' do
    let(:nodes) { (1..49).map { |number| "node#{number}.example.com" } }

    it 'lists and fetches 48 nodes per round and the rest in the next' do
      stub_flat_tree(nodes.to_h { |node| [node, { 'a.txt' => 'a' }] })

      outcomes = client.download('/srv/data', destination_dirs)

      expect(outcomes.values).to all(be_success)
      expect(list_calls.map { |call| call.last.length }).to eq([48, 1])
      expect(get_calls.map { |call| call[:identities].length }).to eq([48, 1])
    end
  end

  it 'fails only the node whose temporary file this host refuses to make, within one round' do
    stub_file_stats
    stub_get
    refuse_first_temporary_file

    outcomes = client.download('/var/log/app.log', destination_dirs)

    expect(get_calls.map { |call| call[:identities] }).to eq([[node2]])
    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include("#{File.join(dir_for(node1), 'app.log')} could not be written from #{node1}", 'Errno::EMFILE')
    expect(outcomes[node2]).to be_success
    expect(File.binread(File.join(dir_for(node2), 'app.log'))).to eq('b' * 100)
    expect(Dir.children(dir_for(node1))).to be_empty
  end

  # The gem raises on a reply whose data is nil while it builds the result,
  # before the library sees it, so an array stands in for data that is not
  # a hash.
  it 'fails a node whose stat reply carries no data hash' do
    stub_stat { |_args, names| names.map { |name| rpc_result(name, []) } }

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('without usable data')
  end

  it 'reports the node when its own directory cannot be made locally' do
    stub_file_stats
    stub_get
    # A plain file where the node's own directory has to go.
    File.write(dir_for(node1), 'in the way')

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('could not be written')
    expect(Dir.children(destination)).to eq([node1])
  end

  it 'removes the copy beside the destination when the rename onto it fails' do
    # One byte past the longest name the filesystem allows, so the copy
    # beside it lands and the rename onto it fails.
    too_long = 'n' * 256
    stub_file_stats(node1 => 'seven b')
    stub_get(node1 => 'seven b')

    outcomes = client.download("/var/log/#{too_long}", destination_dirs.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('could not be written')
    expect(Dir.children(dir_for(node1))).to be_empty
  end

  it 'refuses to place a download where a directory already stands, before asking for anything' do
    stub_file_stats
    stub_get
    standing = File.join(dir_for(node1), 'app.log')
    FileUtils.mkdir_p(standing)

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(get_calls).to be_empty
    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('is a directory')
    expect(Dir.children(standing)).to be_empty
  end

  it 'replaces a file already standing at the destination' do
    stub_file_stats
    stub_get
    FileUtils.mkdir_p(dir_for(node1))
    File.write(File.join(dir_for(node1), 'app.log'), 'the old copy')

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1]).to be_success
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 12_000)
  end

  it 'replaces a symbolic link at the destination and leaves what it pointed at alone' do
    stub_file_stats
    stub_get
    FileUtils.mkdir_p(dir_for(node1))
    elsewhere = File.join(workdir, 'elsewhere.log')
    File.write(elsewhere, 'the link target')
    File.symlink(elsewhere, File.join(dir_for(node1), 'app.log'))

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1]).to be_success
    expect(File.symlink?(File.join(dir_for(node1), 'app.log'))).to be(false)
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 12_000)
    expect(File.read(elsewhere)).to eq('the link target')
  end

  it 'reports a source that does not exist' do
    stub_stat { |_args, names| results_for(names, { exists: false }) }

    outcomes = client.download('/var/log/app.log', destination_dirs.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('does not exist')
  end

  it 'reports a source that is neither a file nor a directory' do
    stub_stat { |_args, names| results_for(names, { exists: true, type: 'fifo' }) }

    outcomes = client.download('/var/run/app.sock', destination_dirs.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('is not a regular file or directory')
  end

  it 'fails every node for a source whose name is not a plain file name, before any call' do
    outcomes = client.download('/srv/data/..', destination_dirs)

    expect(rpc.calls).to be_empty
    expect(outcomes.keys).to eq(nodes)
    expect(outcomes.values.map(&:kind)).to eq([:transfer_failed, :transfer_failed])
    expect(outcomes.values.map(&:message)).to all(include('".." is not a plain file name'))
  end

  # The permission bits the node reported with the owner's bits added,
  # under the umask, as net-scp gives a downloaded file, and without the
  # special bits the node chose.
  it 'places each copy with the permission bits its stat reported, readable and writable by the owner, under the umask, without the setuid bit' do
    stub_file_stats(contents, { node1 => '4640', node2 => '0446' })
    stub_get
    previous = File.umask(0o022)

    begin
      client.download('/var/log/app.log', destination_dirs)
    ensure
      File.umask(previous)
    end

    expect(File.stat(File.join(dir_for(node1), 'app.log')).mode & 0o7777).to eq(0o640)
    expect(File.stat(File.join(dir_for(node2), 'app.log')).mode & 0o7777).to eq(0o644)
  end

  it 'leaves nothing beside the destination when the download is interrupted' do
    stub_file_stats
    stub_get_replies { |_args, _name| raise Interrupt }

    expect { client.download('/var/log/app.log', destination_dirs) }.to raise_error(Interrupt)
    expect(Dir.children(dir_for(node1))).to be_empty
    expect(Dir.children(dir_for(node2))).to be_empty
  end

  it 'leaves nothing beside the destinations when making the temporary files is interrupted' do
    stub_file_stats
    stub_get
    made = 0
    allow(File).to receive(:new).and_wrap_original do |original, path, *args|
      if File.basename(path).start_with?('.file_transfer-')
        made += 1
        raise Interrupt if made == 2
      end

      original.call(path, *args)
    end

    expect { client.download('/var/log/app.log', destination_dirs) }.to raise_error(Interrupt)
    expect(Dir.children(dir_for(node1))).to be_empty
    expect(Dir.children(dir_for(node2))).to be_empty
  end

  it 'fetches a file from the node where the source is one and a tree from the node where it is a directory' do
    stub_stat do |args, names|
      names.map do |name|
        data = if args[:path] == '/srv/data' && name == node2
                 { exists: true, type: 'directory', symlink: false, mode: '0755' }
               else
                 { exists: true, type: 'file', symlink: false, size: 4, mode: '0644', sha256: Digest::SHA256.hexdigest('data') }
               end
        rpc_result(name, data)
      end
    end
    rpc.on(:list) { |_args, names| results_for(names, { entries: [file_entry('inner.txt', 'data')] }) }
    stub_get { |_path, _name| 'data' }

    outcomes = client.download('/srv/data', destination_dirs)

    expect(outcomes.values).to all(be_success)
    expect(File.binread(File.join(dir_for(node1), 'data'))).to eq('data')
    expect(File.binread(File.join(dir_for(node2), 'data', 'inner.txt'))).to eq('data')
  end

  context 'with a directory tree' do
    # Each directory gets the permission bits its node listed with the
    # owner's bits added, under the umask, as net-scp makes a downloaded
    # directory, so a read-only one can still be written while the tree
    # lands, without the special bits the node chose, and the node's own
    # directory above the tree is this host's, under the umask alone.
    it 'creates the listed directories with their permission bits and the owner bits under the umask, and the node directory under the umask alone' do
      stub_stat { |_args, names| results_for(names, { exists: true, type: 'directory', symlink: false, mode: '1777' }) }
      rpc.on(:list) do |_args, names|
        results_for(names, { entries: [{ name: 'empty', type: 'directory', symlink: false, mode: '0555' },
                                       { name: 'open', type: 'directory', symlink: false, mode: '2777' }] })
      end
      previous = File.umask(0o022)

      begin
        outcomes = client.download('/srv/data', destination_dirs.slice(node1))
      ensure
        File.umask(previous)
      end

      expect(outcomes[node1]).to be_success
      expect(File.stat(File.join(dir_for(node1), 'data', 'empty')).mode & 0o7777).to eq(0o755)
      expect(File.stat(File.join(dir_for(node1), 'data', 'open')).mode & 0o7777).to eq(0o755)
      expect(File.stat(File.join(dir_for(node1), 'data')).mode & 0o7777).to eq(0o755)
      expect(File.stat(dir_for(node1)).mode & 0o7777).to eq(0o755)
    end

    { 'a size' => { size: nil }, 'a size at least zero' => { size: -1 }, 'a digest' => { sha256: nil },
      'a mode' => { mode: 'rw-r--r--' } }.each do |field, odd|
      it "reports a node whose file is listed without #{field} and does not ask for it" do
        stub_directory_stats
        rpc.on(:list) { |_args, names| results_for(names, { entries: [file_entry('a.txt', 'abc').merge(odd)] }) }
        rpc.on(:get) { |_args, _names| raise 'the client kept asking for a file it could not bound' }

        outcomes = client.download('/srv/data', destination_dirs.slice(node1))

        expect(rpc.calls.map(&:first)).not_to include(:get)
        expect(outcomes[node1].kind).to eq(:transfer_failed)
        expect(outcomes[node1].message).to include('without a usable size, digest and mode')
      end
    end

    it 'fails the file a node could not read with the reason it gave, and fetches it from the other node' do
      stub_directory_stats
      rpc.on(:list) do |_args, names|
        names.map do |name|
          entry = file_entry('secret.txt', 'top')
          entry = entry.merge(sha256: nil, error: 'Errno::EACCES: Permission denied @ rb_sysopen - /srv/data/secret.txt') if name == node1
          rpc_result(name, { entries: [entry] })
        end
      end
      stub_get { |_path, _name| 'top' }

      outcomes = client.download('/srv/data', destination_dirs)

      expect(get_calls.map { |call| call[:identities] }).to eq([[node2]])
      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include("/srv/data/secret.txt on #{node1} could not be read for its digest: Errno::EACCES: Permission denied")
      expect(outcomes[node2]).to be_success
      expect(downloaded_tree(node2)).to eq(['secret.txt'])
    end

    it 'fails only the node whose listing describes a directory without a usable mode' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' }, node2 => { 'a.txt' => 'a' } })
      rpc.on(:list) do |_args, names|
        names.map do |name|
          entries = [file_entry('a.txt', 'a')]
          entries.unshift({ name: 'sub', type: 'directory', symlink: false, mode: 'drwxr-xr-x' }) if name == node2
          rpc_result(name, { entries: entries })
        end
      end

      outcomes = client.download('/srv/data', destination_dirs)

      expect(outcomes[node1]).to be_success
      expect(outcomes[node2].kind).to eq(:transfer_failed)
      expect(outcomes[node2].message).to include('lists "sub" without a usable mode')
      expect(downloaded_tree(node2)).to be_nil
    end

    it 'fails only the node whose tree root is described without a usable mode, before listing it' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' }, node2 => { 'a.txt' => 'a' } })
      stub_stat do |args, names|
        names.map do |name|
          data = if args[:path] == '/srv/data'
                   { exists: true, type: 'directory', symlink: false, mode: name == node2 ? nil : '0755' }
                 else
                   { exists: true, type: 'file', symlink: false, size: 1, mode: '0644', sha256: Digest::SHA256.hexdigest('a') }
                 end
          rpc_result(name, data)
        end
      end

      outcomes = client.download('/srv/data', destination_dirs)

      expect(list_calls.map(&:last)).to eq([[node1]])
      expect(outcomes[node1]).to be_success
      expect(outcomes[node2].kind).to eq(:transfer_failed)
      expect(outcomes[node2].message).to include("/srv/data on #{node2} was described without a usable mode")
      expect(downloaded_tree(node2)).to be_nil
    end

    it 'asks nothing more of a node whose local directory cannot be made and fetches the rest' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a', 'b.txt' => 'b' }, node2 => { 'a.txt' => 'a', 'b.txt' => 'b' } })
      # A plain file where the tree's own directory has to go.
      FileUtils.mkdir_p(dir_for(node1))
      File.write(File.join(dir_for(node1), 'data'), 'in the way')

      outcomes = client.download('/srv/data', destination_dirs)

      expect(get_calls.map { |call| call[:identities] }.uniq).to eq([[node2]])
      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('could not be created')
      expect(outcomes[node2]).to be_success
      expect(downloaded_tree(node2)).to eq(['a.txt', 'b.txt'])
    end

    it 'asks nothing more of a node that failed on an earlier file and fetches the rest' do
      stub_flat_tree({ node1 => { 'a.txt' => 'aaa', 'b.txt' => 'bbb' }, node2 => { 'a.txt' => 'aaa', 'b.txt' => 'bbb' } })
      # The same length as the stat described, so the digest is what gives it away.
      stub_get do |path, name|
        if path.end_with?('a.txt')
          name == node1 ? 'xxx' : 'aaa'
        else
          'bbb'
        end
      end

      outcomes = client.download('/srv/data', destination_dirs)

      expect(get_calls.select { |call| call[:path] == '/srv/data/b.txt' }.map { |call| call[:identities] }).to eq([[node2]])
      expect(outcomes[node1].kind).to eq(:checksum_mismatch)
      expect(outcomes[node1].message).to include('a.txt')
      expect(outcomes[node2]).to be_success
      expect(downloaded_tree(node2)).to eq(['a.txt', 'b.txt'])
    end

    it 'fetches each file only from the nodes that listed it, so a node missing one keeps the rest' do
      trees = {
        node1 => { 'a.txt' => 'a', 'b.txt' => 'b' },
        node2 => { 'b.txt' => 'b' },
      }
      stub_flat_tree(trees)

      outcomes = client.download('/srv/data', destination_dirs)

      expect(outcomes.values).to all(be_success)
      expect(downloaded_tree(node1)).to eq(['a.txt', 'b.txt'])
      expect(downloaded_tree(node2)).to eq(['b.txt'])
      expect(get_calls.select { |call| call[:path] == '/srv/data/a.txt' }.map { |call| call[:identities] }).to eq([[node1]])
    end

    it 'asks every node for a listing that fits the message data size in one call' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' }, node2 => { 'b.txt' => 'b' } })

      outcomes = client.download('/srv/data', destination_dirs)

      expect(outcomes.values).to all(be_success)
      expect(list_calls).to eq([['/srv/data', nodes]])
      expect(rpc.calls.find { |call| call.first == :list }[1]).to eq(path: '/srv/data', max_bytes: 16 * 1024, checksum: true)
      expect(downloaded_tree(node1)).to eq(['a.txt'])
      expect(downloaded_tree(node2)).to eq(['b.txt'])
    end

    it 'downloads a nested tree from one listing and skips a directory reached through a link' do
      stub_directory_stats
      rpc.on(:list) do |_args, names|
        entries = [{ name: 'linked', type: 'directory', symlink: true }, { name: 'sub', type: 'directory', symlink: false, mode: '0755' },
                   { name: 'sub/deeper', type: 'directory', symlink: false, mode: '0755' }, file_entry('sub/deeper/last.txt', 'last'),
                   file_entry('top.txt', 'top')]
        results_for(names, { entries: entries })
      end
      stub_get { |path, _name| { '/srv/data/top.txt' => 'top', '/srv/data/sub/deeper/last.txt' => 'last' }.fetch(path) }

      outcomes = client.download('/srv/data', destination_dirs.slice(node1))

      tree = File.join(dir_for(node1), 'data')
      expect(outcomes[node1]).to be_success
      expect(outcomes[node1].path).to eq(tree)
      expect(File.read(File.join(tree, 'top.txt'))).to eq('top')
      expect(File.read(File.join(tree, 'sub', 'deeper', 'last.txt'))).to eq('last')
      expect(File.exist?(File.join(tree, 'linked'))).to be(false)
      expect(log.warnings).to include(a_string_including('Skipping /srv/data/linked', 'symbolic link'))
    end

    it 'downloads a link to a file as the file it points at' do
      stub_directory_stats
      rpc.on(:list) { |_args, names| results_for(names, { entries: [file_entry('current.log', 'linked', symlink: true)] }) }
      stub_get { |_path, _name| 'linked' }

      outcomes = client.download('/srv/data', destination_dirs.slice(node1))

      downloaded = File.join(dir_for(node1), 'data', 'current.log')
      expect(outcomes[node1]).to be_success
      expect(File.symlink?(downloaded)).to be(false)
      expect(File.read(downloaded)).to eq('linked')
    end

    it 'downloads the files of a tree and skips with a warning each entry that is neither a file nor a directory' do
      stub_directory_stats
      rpc.on(:list) do |_args, names|
        entries = [{ name: 'app.sock', type: 'other', symlink: false }, { name: 'current.log', type: 'other', symlink: true },
                   file_entry('real.txt', 'real')]
        results_for(names, { entries: entries })
      end
      stub_get { |_path, _name| 'real' }

      outcomes = client.download('/srv/data', destination_dirs.slice(node1))

      tree = File.join(dir_for(node1), 'data')
      expect(outcomes[node1]).to be_success
      expect(Dir.children(tree)).to eq(['real.txt'])
      expect(log.warnings).to include(
        "Skipping /srv/data/app.sock on #{node1}, which is not a regular file or directory",
        "Skipping /srv/data/current.log on #{node1}, which is not a regular file or directory"
      )
    end

    it 'lists every node in one call and gives each its own tree' do
      stub_directory_stats
      rpc.on(:list) do |args, names|
        list_calls << [args[:path], names]
        names.map do |name|
          entries = [file_entry('top.txt', 'top')]
          entries.unshift({ name: 'sub', type: 'directory', symlink: false, mode: '0755' }, file_entry('sub/inner.txt', 'inner')) if name == node1
          rpc_result(name, { entries: entries })
        end
      end
      stub_get { |path, _name| path.end_with?('inner.txt') ? 'inner' : 'top' }

      outcomes = client.download('/srv/data', destination_dirs)

      expect(outcomes.values).to all(be_success)
      expect(list_calls).to eq([['/srv/data', nodes]])
      expect(downloaded_tree(node1)).to eq(['sub', 'top.txt'])
      expect(File.read(File.join(dir_for(node1), 'data', 'sub', 'inner.txt'))).to eq('inner')
      expect(downloaded_tree(node2)).to eq(['top.txt'])
    end

    it 'refuses an entry whose path leaves the tree and writes nothing outside the destination' do
      stub_directory_stats
      rpc.on(:list) { |_args, names| results_for(names, { entries: [file_entry('../../../escaped.txt', 'pwned')] }) }

      outcomes = client.download('/srv/data', destination_dirs.slice(node1))

      expect(rpc.calls.map(&:first)).to eq([:stat, :list])
      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('"../../../escaped.txt", which is not a plain relative path')
      expect(File.exist?(File.join(workdir, 'escaped.txt'))).to be(false)
    end

    it 'fails only the node whose listing the agent refused and downloads the rest' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' }, node2 => { 'a.txt' => 'a' } })
      rpc.on(:list) do |_args, names|
        names.map do |name|
          next rpc_result(name, {}, statuscode: 1, statusmsg: 'The listing of /srv/data does not fit in 16384 bytes at 190 entries') if name == node2

          rpc_result(name, { entries: [file_entry('a.txt', 'a')] })
        end
      end

      outcomes = client.download('/srv/data', destination_dirs)

      expect(outcomes[node1]).to be_success
      expect(outcomes[node2].kind).to eq(:transfer_failed)
      expect(outcomes[node2].message).to include('does not fit in 16384 bytes')
      expect(downloaded_tree(node1)).to eq(['a.txt'])
    end

    it 'fails only the node whose listing is not a list of hashes and downloads the rest' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' }, node2 => { 'a.txt' => 'a' } })
      rpc.on(:list) do |_args, names|
        names.map { |name| rpc_result(name, name == node2 ? { entries: ['a.txt'] } : { entries: [file_entry('a.txt', 'a')] }) }
      end

      outcomes = client.download('/srv/data', destination_dirs)

      expect(outcomes[node1]).to be_success
      expect(outcomes[node2].kind).to eq(:transfer_failed)
      expect(outcomes[node2].message).to include("The file_transfer.list call for /srv/data on #{node2} answered with an unusable listing")
      expect(downloaded_tree(node1)).to eq(['a.txt'])
    end

    it 'creates an empty local tree for a node whose directory holds nothing' do
      stub_directory_stats
      rpc.on(:list) { |_args, names| results_for(names, { entries: [] }) }

      outcomes = client.download('/srv/data', destination_dirs.slice(node1))

      expect(outcomes[node1]).to be_success
      expect(outcomes[node1].path).to eq(File.join(dir_for(node1), 'data'))
      expect(downloaded_tree(node1)).to eq([])
    end
  end
end
