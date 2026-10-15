# frozen_string_literal: true

# The replies and the local directories of a download, shared by the specs
# of Download and Receiver, which both drive Client#download.
module FileTransferDownloadHelpers
  def dir_for(node)
    destination_dirs.fetch(node)
  end

  # The reply to one get, the slice of content the request asked for.
  def get_data(content, args)
    chunk = content.byteslice(args[:offset], args[:max_bytes]) || ''
    { data: encoded(chunk), bytes: chunk.bytesize, size: content.bytesize }
  end

  # Replies to every get, each node with the reply data the block answers
  # for it.
  def stub_get_replies
    rpc.on(:get) do |args, names|
      get_calls << args.merge(identities: names)
      names.map { |name| rpc_result(name, yield(args, name)) }
    end
  end

  # Replies with the slice of each node's content the request asked for.
  # The block answers the content of a path on a node; without one, every
  # node's content comes from files.
  def stub_get(files = contents)
    stub_get_replies do |args, name|
      content = block_given? ? yield(args[:path], name) : files.fetch(name)
      get_data(content, args)
    end
  end

  # Stat replies for a regular file per node, each with the mode in modes
  # or 0644.
  def stub_file_stats(files = contents, modes = {})
    stub_stat do |_args, names|
      names.map do |name|
        content = files.fetch(name)
        rpc_result(name, { exists: true, type: 'file', symlink: false, size: content.bytesize, mode: modes.fetch(name, '0644'), mtime: 0,
                           sha256: Digest::SHA256.hexdigest(content) })
      end
    end
  end

  def stub_directory_stats
    stub_stat { |_args, names| results_for(names, { exists: true, type: 'directory', symlink: false, mode: '0755' }) }
  end

  # A flat remote directory per identity. Every stat lands in stat_paths
  # and every list in list_calls.
  def stub_flat_tree(trees)
    stub_stat do |args, names|
      stat_paths << [args[:path], names.dup]
      names.map do |name|
        content = trees.fetch(name)[File.basename(args[:path])]
        data = if args[:path] == '/srv/data'
                 { exists: true, type: 'directory', symlink: false, mode: '0755' }
               elsif content
                 { exists: true, type: 'file', symlink: false, size: content.bytesize, mode: '0644', sha256: Digest::SHA256.hexdigest(content) }
               else
                 { exists: false }
               end
        rpc_result(name, data)
      end
    end
    rpc.on(:list) do |args, names|
      list_calls << [args[:path], names]
      names.map do |name|
        entries = trees.fetch(name).keys.sort.map { |entry| { name: entry, type: 'file', symlink: false } }
        rpc_result(name, { entries: entries })
      end
    end
    stub_get { |path, name| trees.fetch(name).fetch(File.basename(path)) }
  end

  # The first temporary file beside a destination is refused as if this
  # host had run out of descriptors.
  def refuse_first_temporary_file
    refusals = 0
    allow(File).to receive(:new).and_wrap_original do |original, path, *args|
      temporary = File.basename(path).start_with?('.file_transfer-')
      refusals += 1 if temporary
      raise Errno::EMFILE, 'too many open files' if temporary && refusals == 1

      original.call(path, *args)
    end
  end

  # Every temporary file beside a destination raises the error at its
  # close, after closing, as a full disk does under a buffered write.
  def fail_close_of_temporary_files(error)
    allow(File).to receive(:new).and_wrap_original do |original, path, *args|
      file = original.call(path, *args)
      if File.basename(path).start_with?('.file_transfer-')
        allow(file).to receive(:close).and_wrap_original do |close|
          close.call
          raise error, path
        end
      end
      file
    end
  end

  # The names under the downloaded tree of a node, or nil without a tree.
  def downloaded_tree(node)
    dir = File.join(dir_for(node), 'data')
    File.directory?(dir) ? Dir.children(dir).sort : nil
  end
end

RSpec.shared_context 'with a download client' do
  include_context 'with a file transfer client'
  include FileTransferDownloadHelpers

  let(:destination) { File.join(workdir, 'downloads') }
  let(:destination_dirs) { nodes.to_h { |node| [node, File.join(destination, node)] } }
  let(:contents) { { node1 => 'a' * 12_000, node2 => 'b' * 100 } }
  let(:get_calls) { [] }
  let(:list_calls) { [] }
  let(:stat_paths) { [] }

  before { FileUtils.mkdir_p(destination) }
end
