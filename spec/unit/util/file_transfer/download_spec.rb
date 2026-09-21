# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Client, '#download' do
  include_context 'with a file transfer client'

  let(:destination) { File.join(workdir, 'downloads') }
  let(:destinations) { nodes.to_h { |node| [node, File.join(destination, node)] } }
  let(:contents) { { node1 => 'a' * 12_000, node2 => 'b' * 100 } }
  let(:get_calls) { [] }

  def dir_for(node)
    destinations.fetch(node)
  end

  # The reply to one get, the slice of content the request asked for.
  def get_data(content, args)
    chunk = content.byteslice(args[:offset], args[:max_bytes]) || ''
    { data: encoded(chunk), bytes: chunk.bytesize, eof: args[:offset] + chunk.bytesize >= content.bytesize, size: content.bytesize }
  end

  # Replies with the slice of each node's content the request asked for,
  # through the block form the library writes chunks from. The block
  # answers the content of a path on a node; without one, every node's
  # content comes from files.
  def stub_get(files = contents)
    rpc.on(:get) do |args, names, &block|
      get_calls << args.merge(identities: names)
      names.each do |name|
        content = block_given? ? yield(args[:path], name) : files.fetch(name)
        block.call(nil, rpc_result(name, get_data(content, args)))
      end
      []
    end
  end

  def stub_file_stats(files = contents)
    stub_stat do |_args, names|
      names.map do |name|
        content = files.fetch(name)
        rpc_result(name, { exists: true, type: 'file', symlink: false, size: content.bytesize, mode: '0644', mtime: 0, sha256: Digest::SHA256.hexdigest(content) })
      end
    end
  end

  before do
    stub_put
    FileUtils.mkdir_p(destination)
  end

  it 'fetches the file from every node in rounds and places each verified copy under its node directory' do
    stub_file_stats
    stub_get

    outcomes = client.download('/var/log/app.log', destinations)

    expect(outcomes.keys).to eq(nodes)
    expect(outcomes.values).to all(be_success)
    expect(File.binread(File.join(dir_for(node1), 'app.log'))).to eq('a' * 12_000)
    expect(File.binread(File.join(dir_for(node2), 'app.log'))).to eq('b' * 100)
    expect(outcomes[node1].path).to eq(File.join(dir_for(node1), 'app.log'))
    expect(get_calls.map { |call| call[:offset] }).to eq([0, 5_461, 10_922])
    expect(get_calls.map { |call| call[:identities] }).to eq([nodes, [node1], [node1]])
  end

  it 'creates no session for a download' do
    stub_file_stats
    stub_get

    client.download('/var/log/app.log', destinations)

    expect(rpc.calls.map(&:first)).not_to include(:mktemp)
  end

  context 'with a download group size of one' do
    let(:client_options) { { download_group_size: 1 } }

    it 'downloads one node at a time' do
      stub_file_stats
      stub_get

      client.download('/var/log/app.log', destinations)

      expect(get_calls.first[:identities]).to eq([node1])
      expect(get_calls.map { |call| call[:identities] }).to include([node2])
    end
  end

  it 'reports a file whose content changed during the download and delivers nothing for it' do
    # The same length, so the digest is the only thing that gives it away.
    stub_file_stats(node1 => 'c' * 12_000, node2 => 'b' * 100)
    stub_get

    outcomes = client.download('/var/log/app.log', destinations)

    expect(outcomes[node1].kind).to eq(:checksum_mismatch)
    expect(outcomes[node1].message).to include('changed during the download')
    expect(File.exist?(File.join(dir_for(node1), 'app.log'))).to be(false)
    expect(outcomes[node2]).to be_success
  end

  it 'drops a node that keeps sending past the size its own stat reported' do
    stub_file_stats(node1 => 'a' * 100)
    rpc.on(:get) do |args, names, &block|
      get_calls << args.merge(identities: names)
      chunk = 'a' * args[:max_bytes]
      names.each { |name| block.call(nil, rpc_result(name, { data: encoded(chunk), bytes: chunk.bytesize, eof: false })) }
      []
    end

    outcomes = client.download('/var/log/app.log', destinations.slice(node1))

    expect(get_calls.length).to eq(1)
    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('kept sending past the 100 bytes')
    expect(File.exist?(File.join(dir_for(node1), 'app.log'))).to be(false)
  end

  it 'fails a node whose reply carries more than the bytes the round asked for' do
    stub_file_stats
    oversized = ['x' * 6_000].pack('m0')
    rpc.on(:get) do |_args, names, &block|
      names.each { |name| block.call(nil, rpc_result(name, { data: oversized, bytes: 6_000, eof: false })) }
      []
    end

    outcomes = client.download('/var/log/app.log', destinations.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('6000 bytes, more than the 5461 requested')
  end

  it 'fails a node whose reply is not valid base64' do
    stub_file_stats
    rpc.on(:get) do |_args, names, &block|
      names.each { |name| block.call(nil, rpc_result(name, { data: 'not base64!', bytes: 5, eof: true })) }
      []
    end

    outcomes = client.download('/var/log/app.log', destinations.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include("Writing /var/log/app.log from #{node1} failed")
  end

  it 'fails a node whose stat reply carries no data' do
    stub_stat { |_args, names| names.map { |name| rpc_result(name, nil) } }

    outcomes = client.download('/var/log/app.log', destinations.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('without usable data')
  end

  it 'places a download whose name is as long as the filesystem allows' do
    long_name = 'n' * 250
    stub_file_stats(node1 => 'seven b')
    stub_get(node1 => 'seven b')

    outcomes = client.download("/var/log/#{long_name}", destinations.slice(node1))

    expect(outcomes[node1]).to be_success
    expect(File.binread(File.join(dir_for(node1), long_name))).to eq('seven b')
  end

  it 'reports the node when its download cannot be written locally and leaves no staging file behind' do
    stub_file_stats
    stub_get
    # A plain file where the node's own directory has to go.
    File.write(dir_for(node1), 'in the way')

    outcomes = client.download('/var/log/app.log', destinations.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('could not be written')
    expect(Dir.children(destination)).to eq([node1])
  end

  context 'when a node stays silent for a get' do
    it 'reports it as not responding after one round' do
      stub_file_stats(node1 => 'a' * 30_000)
      rpc.on(:get) do |args, names|
        get_calls << args.merge(identities: names)
        []
      end

      outcomes = client.download('/var/log/app.log', destinations.slice(node1))

      expect(get_calls.map { |call| [call[:offset], call[:max_bytes]] }).to eq([[0, 5_461]])
      expect(outcomes[node1].kind).to eq(:no_response)
    end
  end

  it 'refuses to place a download where a directory already stands' do
    stub_file_stats
    stub_get
    standing = File.join(dir_for(node1), 'app.log')
    FileUtils.mkdir_p(standing)

    outcomes = client.download('/var/log/app.log', destinations.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('is a directory')
    expect(Dir.children(standing)).to be_empty
  end

  it 'reports a source that does not exist' do
    stub_stat { |_args, names| results_for(names, { exists: false }) }

    outcomes = client.download('/var/log/app.log', destinations.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('does not exist')
  end

  it 'reports a source that is neither a file nor a directory' do
    stub_stat { |_args, names| results_for(names, { exists: true, type: 'fifo' }) }

    outcomes = client.download('/var/run/app.sock', destinations.slice(node1))

    expect(outcomes[node1].kind).to eq(:transfer_failed)
    expect(outcomes[node1].message).to include('is not a regular file or directory')
  end

  it 'downloads a directory tree and skips a directory reached through a link' do
    stub_stat do |args, names|
      names.map do |name|
        data = case args[:path]
               when '/srv/data' then { exists: true, type: 'directory', symlink: false }
               when '/srv/data/top.txt' then { exists: true, type: 'file', size: 3, sha256: Digest::SHA256.hexdigest('top') }
               when '/srv/data/sub/inner.txt' then { exists: true, type: 'file', size: 5, sha256: Digest::SHA256.hexdigest('inner') }
               end
        rpc_result(name, data)
      end
    end
    rpc.on(:list) do |args, names|
      entries = case args[:path]
                when '/srv/data'
                  [{ name: 'linked', type: 'directory', symlink: true }, { name: 'sub', type: 'directory', symlink: false }, { name: 'top.txt', type: 'file', symlink: false }]
                when '/srv/data/sub'
                  [{ name: 'inner.txt', type: 'file', symlink: false }]
                end
      results_for(names, { entries: entries, total: entries.length })
    end
    rpc.on(:get) do |args, names, &block|
      content = { '/srv/data/top.txt' => 'top', '/srv/data/sub/inner.txt' => 'inner' }.fetch(args[:path])
      names.each do |name|
        block.call(nil, rpc_result(name, { data: encoded(content), bytes: content.bytesize, eof: true, size: content.bytesize }))
      end
      []
    end

    outcomes = client.download('/srv/data', destinations.slice(node1))

    tree = File.join(dir_for(node1), 'data')
    expect(outcomes[node1]).to be_success
    expect(outcomes[node1].path).to eq(tree)
    expect(File.read(File.join(tree, 'top.txt'))).to eq('top')
    expect(File.read(File.join(tree, 'sub', 'inner.txt'))).to eq('inner')
    expect(File.exist?(File.join(tree, 'linked'))).to be(false)
    expect(log.warnings).to include(a_string_including('Skipping /srv/data/linked', 'symbolic link'))
  end

  context 'with a directory whose listing comes from the node' do
    let(:list_calls) { [] }
    let(:stat_paths) { [] }

    # A flat remote directory per identity, each node paging its own
    # listing at its own page size.
    def stub_flat_tree(trees, page_sizes)
      stub_stat do |args, names|
        stat_paths << [args[:path], names.dup]
        names.map do |name|
          content = trees.fetch(name)[File.basename(args[:path])]
          data = if args[:path] == '/srv/data'
                   { exists: true, type: 'directory', symlink: false }
                 elsif content
                   { exists: true, type: 'file', symlink: false, size: content.bytesize, sha256: Digest::SHA256.hexdigest(content) }
                 else
                   { exists: false }
                 end
          rpc_result(name, data)
        end
      end
      rpc.on(:list) do |args, names|
        list_calls << [args[:offset], names]
        names.map do |name|
          all = trees.fetch(name).keys.sort
          page = all[args[:offset], page_sizes.fetch(name)] || []
          entries = page.map { |entry| { name: entry, type: 'file', symlink: false } }
          rpc_result(name, { entries: entries, total: all.length })
        end
      end
      stub_get { |path, name| trees.fetch(name).fetch(File.basename(path)) }
    end

    def stub_directory_stats
      stub_stat { |_args, names| results_for(names, { exists: true, type: 'directory', symlink: false }) }
    end

    def downloaded_tree(node)
      dir = File.join(dir_for(node), 'data')
      File.directory?(dir) ? Dir.children(dir).sort : nil
    end

    it 'refuses an entry name that is not a plain file name and writes nothing outside the destination' do
      stub_stat do |args, names|
        data = args[:path] == '/srv/data' ? { exists: true, type: 'directory', symlink: false } : { exists: true, type: 'file', size: 5, sha256: Digest::SHA256.hexdigest('pwned') }
        names.map { |name| rpc_result(name, data) }
      end
      rpc.on(:list) { |_args, names| results_for(names, { entries: [{ name: '../../../escaped.txt', type: 'file', symlink: false }], total: 1 }) }

      outcomes = client.download('/srv/data', destinations.slice(node1))

      expect(rpc.calls.map(&:first)).not_to include(:get)
      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('not a plain file name')
      expect(File.exist?(File.join(workdir, 'escaped.txt'))).to be(false)
    end

    it 'refuses an entry name carrying a separator the client platform would split on' do
      stub_directory_stats
      rpc.on(:list) { |_args, names| results_for(names, { entries: [{ name: 'back\\slash', type: 'file', symlink: false }], total: 1 }) }

      outcomes = client.download('/srv/data', destinations.slice(node1))

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('not a plain file name')
    end

    it 'fails only the node whose listing has no entries and downloads the rest' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' }, node2 => { 'a.txt' => 'a' } }, { node1 => 10, node2 => 10 })
      rpc.on(:list) do |_args, names|
        names.map do |name|
          data = name == node2 ? { total: 1 } : { entries: [{ name: 'a.txt', type: 'file', symlink: false }], total: 1 }
          rpc_result(name, data)
        end
      end

      outcomes = client.download('/srv/data', destinations)

      expect(outcomes[node1]).to be_success
      expect(outcomes[node2].kind).to eq(:transfer_failed)
      expect(outcomes[node2].message).to include('unusable listing')
      expect(downloaded_tree(node1)).to eq(['a.txt'])
    end

    it 'pages each node from its own offset so a shorter page loses nothing' do
      trees = {
        node1 => (1..6).to_h { |index| ["a#{index}.txt", "a#{index}"] },
        node2 => (1..4).to_h { |index| ["b#{index}.txt", "b#{index}"] },
      }
      stub_flat_tree(trees, { node1 => 3, node2 => 2 })

      outcomes = client.download('/srv/data', destinations)

      expect(outcomes.values).to all(be_success)
      expect(downloaded_tree(node1)).to eq(['a1.txt', 'a2.txt', 'a3.txt', 'a4.txt', 'a5.txt', 'a6.txt'])
      expect(downloaded_tree(node2)).to eq(['b1.txt', 'b2.txt', 'b3.txt', 'b4.txt'])
      expect(list_calls).to include([2, [node2]], [3, [node1]])
    end

    it 'reports the node when a listed file can no longer be stat-ed' do
      stub_stat do |args, names|
        data = args[:path] == '/srv/data' ? { exists: true, type: 'directory', symlink: false } : { exists: false }
        names.map { |name| rpc_result(name, data) }
      end
      rpc.on(:list) { |_args, names| results_for(names, { entries: [{ name: 'gone.txt', type: 'file', symlink: false }], total: 1 }) }

      outcomes = client.download('/srv/data', destinations.slice(node1))

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('does not exist')
    end

    it 'reports a node whose file is described without a size and stops asking for it' do
      stub_stat do |args, names|
        data = if args[:path] == '/srv/data'
                 { exists: true, type: 'directory', symlink: false }
               else
                 { exists: true, type: 'file', symlink: false, size: nil, sha256: Digest::SHA256.hexdigest('abc') }
               end
        names.map { |name| rpc_result(name, data) }
      end
      rpc.on(:list) { |_args, names| results_for(names, { entries: [{ name: 'a.txt', type: 'file', symlink: false }], total: 1 }) }
      rpc.on(:get) { |_args, _names| raise 'the client kept asking for a file it could not bound' }

      outcomes = client.download('/srv/data', destinations.slice(node1))

      expect(rpc.calls.map(&:first)).not_to include(:get)
      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('without a usable size and digest')
    end

    it 'reports the node when a local directory cannot be made for its tree' do
      stub_flat_tree({ node1 => { 'a.txt' => 'a' } }, { node1 => 10 })
      # A plain file where the tree's own directory has to go.
      FileUtils.mkdir_p(dir_for(node1))
      File.write(File.join(dir_for(node1), 'data'), 'in the way')

      outcomes = client.download('/srv/data', destinations.slice(node1))

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('could not be created')
    end

    it 'reports the node when the tree would land outside its directory' do
      stub_directory_stats
      rpc.on(:list) { |_args, names| results_for(names, { entries: [], total: 0 }) }

      outcomes = client.download('/srv/data/..', destinations.slice(node1))

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('would land outside')
    end

    it 'fails only the node whose listed file is described as something else' do
      stub_flat_tree({ node1 => { 'one.txt' => 'one' }, node2 => { 'one.txt' => 'one' } }, { node1 => 10, node2 => 10 })
      stub_stat do |args, names|
        names.map do |name|
          data = if args[:path] == '/srv/data'
                   { exists: true, type: 'directory', symlink: false }
                 elsif name == node1
                   { exists: true, type: 'directory', symlink: false, size: nil, sha256: nil }
                 else
                   { exists: true, type: 'file', symlink: false, size: 3, sha256: Digest::SHA256.hexdigest('one') }
                 end
          rpc_result(name, data)
        end
      end
      # node1 would keep sending without eof if it were ever asked, which
      # is the case that reached the size comparison before the check.
      rpc.on(:get) do |_args, names, &block|
        names.each { |name| block.call(nil, rpc_result(name, { data: encoded('one'), bytes: 3, eof: name == node2, size: 3 })) }
        []
      end

      outcomes = client.download('/srv/data', destinations)

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('was listed as a file and is no longer one')
      expect(outcomes[node2]).to be_success
    end

    it 'refuses an entry name that is not valid in its encoding' do
      stub_directory_stats
      rpc.on(:list) do |_args, names|
        name = JSON.parse('["a\\udcffb"]').first
        results_for(names, { entries: [{ name: name, type: 'file', symlink: false }], total: 1 })
      end

      outcomes = client.download('/srv/data', destinations.slice(node1))

      expect(outcomes[node1].kind).to eq(:transfer_failed)
      expect(outcomes[node1].message).to include('not a plain file name')
    end

    it 'stats each file only on the nodes that listed it, so a node missing one keeps the rest' do
      trees = {
        node1 => { 'a.txt' => 'a', 'b.txt' => 'b' },
        node2 => { 'b.txt' => 'b' },
      }
      stub_flat_tree(trees, { node1 => 10, node2 => 10 })

      outcomes = client.download('/srv/data', destinations)

      expect(outcomes.values).to all(be_success)
      expect(downloaded_tree(node1)).to eq(['a.txt', 'b.txt'])
      expect(downloaded_tree(node2)).to eq(['b.txt'])
      expect(stat_paths).to include(['/srv/data/a.txt', [node1]])
      expect(stat_paths.count { |path, _names| path == '/srv/data/a.txt' }).to eq(1)
    end
  end
end
