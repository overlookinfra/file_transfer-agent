# frozen_string_literal: true

require 'digest/sha2'
require 'fileutils'
require 'securerandom'
require 'tmpdir'
require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # Fetching a file or a tree from every node into a local directory per
      # node, in rounds of get across groups of nodes, each copy verified
      # against the digest the node reported before it was read.
      class Download
        DOWNLOADABLE_TYPES = ['file', 'directory'].freeze
        # A name Windows treats as a device rather than a file, with or
        # without an extension.
        WINDOWS_RESERVED_NAMES = /\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?\z/i

        # @param transfer [Transfer] The nodes to fetch from, which drop out as steps fail
        # @param rpc [Rpc]
        # @param chunk [Integer] The bytes of file content one get reply is asked for
        # @param logger [#debug, #warn]
        def initialize(transfer:, rpc:, chunk:, logger:)
          @transfer = transfer
          @rpc = rpc
          @chunk = chunk
          @logger = logger
        end

        # See Client#download.
        def run(source, destinations)
          described = describe_sources(@transfer.active, source)
          files = @transfer.active.select { |identity| described[identity][:type] == 'file' }
          trees = @transfer.active - files
          delivered = {}
          Dir.mktmpdir('file_transfer-download') do |staging|
            unless files.empty?
              landing = files.to_h { |identity| [identity, File.join(destinations[identity], File.basename(source))] }
              delivered.merge!(download_files(source, described, staging, landing))
            end
            delivered.merge!(download_trees(trees, source, destinations, staging)) unless trees.empty?
          end
          @transfer.outcomes { |identity| delivered[identity] }
        end

        private

        # stat with checksum on the identities, which digests the whole file
        # on the node, so the call waits the digest timeout. Files and
        # directories continue, anything else is a failure for that node.
        def describe_sources(identities, source)
          response = @rpc.call(identities, "file_transfer.stat #{source}", timeout: @rpc.digest_timeout) do |client|
            client.stat(path: source, checksum: true)
          end
          @transfer.fail(response.errors)
          described = {}
          errors = {}
          response.responded.each do |identity, data|
            if !data[:exists]
              errors[identity] = Outcome.failure(identity, :transfer_failed, "#{source} does not exist on #{identity}")
            elsif !DOWNLOADABLE_TYPES.include?(data[:type])
              errors[identity] = Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} is not a regular file or directory")
            elsif data[:type] == 'file' && !file_described?(data)
              # Without a size and a digest the transfer has nothing to stop
              # at and nothing to verify against, so the node cannot be read from.
              errors[identity] = Outcome.failure(identity, :transfer_failed,
                "#{source} on #{identity} was described without a usable size and digest")
            else
              described[identity] = data
            end
          end
          @transfer.fail(errors)
          described
        end

        def file_described?(data)
          data[:size].is_a?(Integer) && !data[:size].negative? && data[:sha256].is_a?(String)
        end

        # Fetches one remote file from the identities in landing, in
        # batches, and moves each verified copy from the staging directory
        # onto the local path landing names for its identity. Answers the
        # final local path per identity that succeeded.
        #
        # @param landing [Hash{String => String}] Identity to the local path its copy ends up at
        def download_files(remote, described, staging, landing)
          identities = landing.keys
          delivered = {}
          identities.each_slice(@rpc.download_batch_size) do |group|
            fetch_file(group, remote, staging, described, @chunk).each do |identity, staged|
              placed = place_download(identity, staged, landing[identity])
              delivered[identity] = placed if placed
            end
          end
          delivered
        end

        # Moves a verified copy onto its final path and answers that path, or
        # nil when it could not be placed. A directory already there is an
        # error rather than a place to nest the file in, and the copy crosses
        # filesystems beside its destination first, so the final path is
        # never half written.
        def place_download(identity, staged, final)
          if File.directory?(final)
            @transfer.fail(identity => Outcome.failure(identity, :transfer_failed,
              "#{final} is a directory, so the download from #{identity} was not placed there"))
            return nil
          end

          # A name of fixed length, so a destination name near the
          # filesystem's limit still fits beside it.
          beside = File.join(File.dirname(final), ".file_transfer-#{SecureRandom.hex(8)}")
          begin
            FileUtils.mkdir_p(File.dirname(final))
            FileUtils.mv(staged, beside)
            File.rename(beside, final)
            final
          rescue SystemCallError => e
            FileUtils.rm_f(beside)
            @transfer.fail(identity => Outcome.failure(identity, :transfer_failed,
              "#{final} could not be written from #{identity}: #{e.class}: #{e.message}"))
            nil
          end
        end

        # One round of get per offset for the whole group, every reply
        # written to that node's staging file as it arrives. A node leaves
        # the group at eof, and a node still sending past the size stat
        # reported is dropped. The digest of each complete file is compared
        # with the one stat reported before the transfer started.
        def fetch_file(group, remote, staging, expected, max_bytes)
          handles = group.to_h { |identity| [identity, File.new(File.join(staging, SecureRandom.hex(16)), 'wb')] }
          pending = group.dup
          offset = 0
          begin
            while @transfer.active? && !pending.empty?
              pending &= @transfer.active
              break if pending.empty?

              pending -= fetch_round(pending, remote, offset, max_bytes, handles)
              pending &= @transfer.active
              offset += max_bytes
              over = pending.select { |identity| offset >= expected[identity][:size] }
              @transfer.fail(Outcome.failures(over, :transfer_failed) { |identity| "#{remote} on #{identity} kept sending past the #{expected[identity][:size]} bytes stat reported" })
            end
          ensure
            handles.each_value(&:close)
          end
          verify_downloads(group, remote, handles, expected)
        end

        # Answers the identities that reached eof.
        def fetch_round(pending, remote, offset, max_bytes, handles)
          asked = pending.to_set
          finished = []
          write_errors = {}
          response = @rpc.call(pending, "file_transfer.get #{remote}") do |client|
            collected = []
            client.get(path: remote, offset: offset, max_bytes: max_bytes) do |_payload, result|
              collected << result
              identity = result[:sender]
              next unless asked.include?(identity) && result[:statuscode].zero?

              begin
                data = result[:data]
                raise 'the reply carries no data' unless data.is_a?(Hash)

                chunk = data[:data].to_s.unpack1('m0')
                # The node decides what the reply says, so more content
                # than the request asked for is refused.
                raise "the reply carries #{chunk.bytesize} bytes, more than the #{max_bytes} requested" if chunk.bytesize > max_bytes

                handles[identity].seek(offset)
                handles[identity].write(chunk)
                finished << identity if data[:eof]
                # The chunk is on disk, so the reply need not hold it for
                # the rest of the round.
                data.delete(:data)
              rescue StandardError => e
                @logger.debug(e.backtrace.join("\n")) if e.backtrace
                write_errors[identity] = Outcome.failure(identity, :transfer_failed,
                  "Writing #{remote} from #{identity} failed: #{e.class}: #{e.message}")
              end
            end
            collected
          end
          @transfer.fail(response.errors)
          @transfer.fail(write_errors)
          finished - write_errors.keys
        end

        def verify_downloads(group, remote, handles, expected)
          digests = (group & @transfer.active).to_h { |identity| [identity, Digest::SHA256.file(handles[identity].path).hexdigest] }
          matched, changed = digests.partition { |identity, actual| actual == expected[identity][:sha256] }
          @transfer.fail(Outcome.failures(changed.map(&:first), :checksum_mismatch) do |identity|
            "#{remote} on #{identity} changed during the download: expected #{expected[identity][:sha256]}, got #{digests[identity]}"
          end)
          matched.to_h { |identity, _actual| [identity, handles[identity].path] }
        end

        # Lists the remote tree on every node, then fetches each file from
        # the nodes that have it. Trees that differ between nodes are handled
        # file by file.
        def download_trees(identities, source, destinations, staging)
          directories, files = walk_remote_tree(identities, source)
          delivered = create_tree_directories(directories, destinations, source)
          download_tree_files(files, source, destinations, staging)
          delivered.slice(*@transfer.active)
        end

        # The directories and the files of the tree, breadth first, each as
        # its path relative to the source with the identities that have it.
        # Directories reached through a symbolic link are skipped with a
        # warning, so the walk cannot loop. Entry names come from the node,
        # so each one has to be a plain file name before it becomes part of
        # a local path.
        def walk_remote_tree(identities, source)
          files = Hash.new { |hash, key| hash[key] = [] }
          directories = Hash.new { |hash, key| hash[key] = [] }
          queue = [['', identities]]
          until queue.empty?
            relative, group = queue.shift
            group &= @transfer.active
            next if group.empty?

            remote_dir = relative.empty? ? source : File.join(source, relative)
            subdirectories = Hash.new { |hash, key| hash[key] = [] }
            list_remote(group, remote_dir).each do |identity, entries|
              odd = entries.find { |entry| !plain_name?(entry[:name]) }
              if odd
                @transfer.fail(identity => Outcome.failure(identity, :transfer_failed,
                  "#{remote_dir} on #{identity} lists #{odd[:name].inspect}, which is not a plain file name"))
                next
              end

              directories[relative] << identity
              entries.each do |entry|
                child = relative.empty? ? entry[:name] : File.join(relative, entry[:name])
                if entry[:type] == 'directory' && entry[:symlink]
                  @logger.warn("Skipping #{File.join(remote_dir, entry[:name])} on #{identity}, a symbolic link to a directory")
                elsif entry[:type] == 'directory'
                  subdirectories[child] << identity
                elsif entry[:type] == 'file'
                  files[child] << identity
                end
              end
            end
            subdirectories.each { |child, subgroup| queue.push([child, subgroup]) }
          end
          [directories, files]
        end

        # Creates every listed directory locally, the root first, and
        # answers the local root per identity that got one.
        def create_tree_directories(directories, destinations, source)
          delivered = {}
          directories.each do |relative, group|
            (group & @transfer.active).each do |identity|
              local = tree_path_for(identity, destinations, source, relative)
              next if local.nil?

              begin
                FileUtils.mkdir_p(local)
              rescue SystemCallError => e
                @transfer.fail(identity => Outcome.failure(identity, :transfer_failed,
                  "#{local} could not be created for #{identity}: #{e.class}: #{e.message}"))
                next
              end
              delivered[identity] ||= local
            end
          end
          delivered
        end

        # Fetches every listed file from the nodes that listed it.
        def download_tree_files(files, source, destinations, staging)
          files.each do |relative, group|
            remote = File.join(source, relative)
            group &= @transfer.active
            next if group.empty?

            expected = describe_sources(group, remote)
            group &= expected.keys
            # The listing said file, so anything else now is the node's
            # problem, and only a file description carries the size and
            # digest below.
            changed = group.reject { |identity| expected[identity][:type] == 'file' }
            @transfer.fail(Outcome.failures(changed, :transfer_failed) { |identity| "#{remote} on #{identity} was listed as a file and is no longer one" })
            group -= changed
            landing = group.to_h { |identity| [identity, tree_path_for(identity, destinations, source, relative)] }.compact
            next if landing.empty?

            download_files(remote, expected, staging, landing)
          end
        end

        # The local path for one entry of a downloaded tree, or nil once the
        # node has been failed because that path would leave its directory,
        # since the shape of the tree is the node's to choose.
        def tree_path_for(identity, destinations, source, relative)
          root = File.expand_path(destinations[identity])
          base = File.join(root, File.basename(source))
          path = relative.empty? ? base : File.join(base, relative)
          expanded = File.expand_path(path)
          return path if expanded == root || expanded.start_with?(root + File::SEPARATOR)

          @transfer.fail(identity => Outcome.failure(identity, :transfer_failed,
            "The tree of #{source} from #{identity} would land outside #{destinations[identity]}"))
          nil
        end

        # A listed name may become one component of a local path, so it has
        # to be one component on either client platform. A backslash is a
        # separator on Windows, and the agent's own DDL refuses it in a
        # name, so it is refused here too rather than relying on the
        # containment check to catch what it turns into. On a Windows
        # controller a device name, a colon, or a trailing dot or space
        # would not stay an ordinary file either.
        def plain_name?(name)
          return false unless name.is_a?(String) && !name.empty? && name.valid_encoding?
          return false if ['.', '..'].include?(name)
          return false if name.match?(%r{[/\\\x00]})
          return true unless Gem.win_platform?

          !name.include?(':') && !name.match?(WINDOWS_RESERVED_NAMES) && !name.end_with?('.', ' ')
        end

        # Every entry of a remote directory per node, paging through list
        # with a cursor per node, since each node's pages are its own.
        def list_remote(group, remote_dir)
          listed = group.to_h { |identity| [identity, []] }
          offsets = group.to_h { |identity| [identity, 0] }
          pending = group.dup
          until pending.empty?
            pending.group_by { |identity| offsets[identity] }.each do |offset, page_identities|
              response = @rpc.call(page_identities, "file_transfer.list #{remote_dir}") { |client| client.list(path: remote_dir, offset: offset) }
              @transfer.fail(response.errors)
              pending -= response.errors.keys
              response.responded.each do |identity, data|
                entries = listing_entries(data)
                if entries.nil?
                  @transfer.fail(identity => Outcome.failure(identity, :transfer_failed,
                    "file_transfer.list #{remote_dir} on #{identity} answered with an unusable listing"))
                  pending -= [identity]
                  next
                end

                listed[identity].concat(entries)
                offsets[identity] += entries.length
                pending -= [identity] if entries.empty? || offsets[identity] >= data[:total]
              end
            end
          end
          listed.slice(*@transfer.active)
        end

        # The entries of one list reply with symbol keys, or nil when the
        # reply does not have the shape the DDL promises.
        def listing_entries(data)
          entries = data[:entries]
          return nil unless entries.is_a?(Array) && data[:total].is_a?(Integer)

          entries.map do |entry|
            return nil unless entry.is_a?(Hash)

            entry.transform_keys(&:to_sym)
          end
        end
      end
    end
  end
end
