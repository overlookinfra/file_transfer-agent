# frozen_string_literal: true

require 'fileutils'
require_relative 'local_path'
require_relative 'outcome'
require_relative 'receiver'

module MCollective
  module Util
    module FileTransfer
      # One download: what happened to each node. run is the whole
      # lifecycle: stat with a checksum on every node, each file through the
      # Receiver, which assembles every copy beside its destination, and for
      # a tree one list call to the nodes, then the local directories and
      # the files it named, one Outcome per node. Reads no chunks itself.
      class Download
        DOWNLOADABLE_TYPES = ['file', 'directory'].freeze
        # A mode as the agent reports one, three or four octal digits.
        MODE = /\A[0-7]{3,4}\z/

        # @param rpc [Rpc]
        # @param logger [#debug, #warn]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
          @receiver = Receiver.new(rpc: rpc, logger: logger)
        end

        # See Client#download.
        #
        # @param source [String] The path on every node, valid UTF-8
        # @param destination_dirs [Hash{String => String}] Identity to the local directory that
        #   receives its copy, each valid UTF-8
        # @return [Hash{String => Outcome}] By identity
        def run(source, destination_dirs)
          identities = destination_dirs.keys
          # The copies land under the source's name, so a name that is not
          # one plain component fails every node before any call.
          name = LocalPath.last_component(source)
          unless LocalPath.plain_name?(name)
            return Outcome.failures(identities, :transfer_failed) do |identity|
              "The source name #{name.inspect} is not a plain file name, so #{source} cannot be placed for #{identity}"
            end
          end

          stats, failures = stat_sources(identities, source)
          files, trees = stats.partition { |_identity, data| data[:type] == 'file' }.map(&:to_h)
          delivered = {}
          unless files.empty?
            destinations = files.to_h { |identity, _data| [identity, File.join(destination_dirs[identity], name)] }
            placed, file_failures = fetch_files(source, files, destinations)
            delivered.merge!(placed)
            failures.merge!(file_failures)
          end
          unless trees.empty?
            # Trees that differ between nodes are fetched file by file.
            roots, tree_failures = fetch_trees(source, trees, destination_dirs)
            delivered.merge!(roots)
            failures.merge!(tree_failures)
          end
          Outcome.per_identity(identities, failures, delivered)
        end

        private

        # Runs stat with a checksum on the identities. Files and directories
        # continue, and anything else is a failure for that node.
        #
        # @param identities [Array<String>] The nodes to ask
        # @param source [String] The path on every node
        # @return [Array(Hash{String => Hash}, Hash{String => Outcome})] The stat data per
        #   identity that can be read from, and the failures
        def stat_sources(identities, source)
          response = @rpc.call(identities, "file_transfer.stat #{source}") { |client| client.stat(path: source, checksum: true) }
          failures = response.errors.dup
          stats = {}
          response.responded.each do |identity, data|
            if !data[:exists]
              failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} does not exist on #{identity}")
            elsif !DOWNLOADABLE_TYPES.include?(data[:type])
              failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} is not a regular file or directory")
            elsif !described?(data)
              fields = data[:type] == 'file' ? 'size, digest and mode' : 'mode'
              failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} was described without a usable #{fields}")
            else
              stats[identity] = data
            end
          end
          [stats, failures]
        end

        # Whether a stat reply carries what the download rests on: the mode
        # the copy gets, and for a file the size the rounds stop at and the
        # digest the copy is verified against. The node decides what the
        # reply says, so each is checked before it is used.
        #
        # @param data [Hash] The stat reply data
        # @return [Boolean]
        def described?(data)
          return false unless mode?(data[:mode])
          return true unless data[:type] == 'file'

          data[:size].is_a?(Integer) && !data[:size].negative? && data[:sha256].is_a?(String)
        end

        # @param value [Object] A mode as a node reported it
        # @return [Boolean]
        def mode?(value)
          value.is_a?(String) && value.match?(MODE)
        end

        # Receives one remote file from the identities in destinations and
        # places each verified copy at the local path destinations maps its
        # identity to. Each destination's directory is made first, and a
        # directory already standing at a destination is that node's
        # failure, not a place to put the file inside, both before any call.
        #
        # @param source [String] The path on every node
        # @param stats [Hash{String => Hash}] Identity to its stat reply data
        # @param destinations [Hash{String => String}] Identity to the local path its copy ends up at
        # @return [Array(Hash{String => String}, Hash{String => Outcome})] The final local path
        #   per identity whose copy was placed, and the failures
        def fetch_files(source, stats, destinations)
          failures = {}
          destinations.each do |identity, destination|
            if File.directory?(destination)
              failures[identity] = Outcome.failure(identity, :transfer_failed, "#{destination} is a directory, so the download from #{identity} was not placed there")
              next
            end

            FileUtils.mkdir_p(File.dirname(destination))
          rescue SystemCallError => e
            failures[identity] = Outcome.failure(identity, :transfer_failed, "#{destination} could not be written from #{identity}: #{e.class}: #{e.message}")
          end
          placed, receive_failures = @receiver.receive_file(source, stats, destinations.except(*failures.keys))
          [placed, failures.merge(receive_failures)]
        end

        # Downloads the tree under the source from the nodes in stats: one
        # list call per round, the local directories, then every listed
        # file, each step shrinking the nodes still pending.
        #
        # @param source [String] The directory on every node
        # @param stats [Hash{String => Hash}] Identity to its stat reply data, for the nodes
        #   where the source is a directory
        # @param destination_dirs [Hash{String => String}] Identity to its local directory
        # @return [Array(Hash{String => String}, Hash{String => Outcome})] The local root per
        #   identity whose tree came through, and the failures
        def fetch_trees(source, stats, destination_dirs)
          identities = stats.keys
          directories, files, failures = list_trees(stats, source)
          pending = identities - failures.keys
          roots, directory_failures = create_tree_directories(directories, destination_dirs, source, pending)
          failures.merge!(directory_failures)
          pending -= failures.keys
          failures.merge!(fetch_tree_files(files, source, destination_dirs, pending))
          pending -= failures.keys
          [roots.slice(*pending), failures]
        end

        # Lists the tree under the source on the nodes, a download round at
        # a time since every reply may weigh the message data size. The
        # agent answers every entry with its path relative to the source,
        # parents before their contents, and refuses a tree that lists
        # larger than the message data size, which fails that node. A
        # directory reached through a symbolic link comes without its
        # contents and is skipped here with a warning, and so is anything
        # that is neither a file nor a directory. Every path comes from the
        # node, so each one has to be plain components all the way down
        # before it is joined to a local path, and every directory's mode is
        # checked before it is applied. The root's mode is the one its stat
        # reported.
        #
        # @param stats [Hash{String => Hash}] Identity to its stat reply data, for the nodes
        #   where the source is a directory
        # @param source [String] The directory on every node
        # @return [Array(Hash{String => Hash{String => String}}, Hash{String => Array<String>}, Hash{String => Outcome})] The
        #   directories as relative path to the mode per identity that has it, the files as
        #   relative path to the identities that have it, and the failures
        def list_trees(stats, source)
          directories = Hash.new { |hash, key| hash[key] = {} }
          files = Hash.new { |hash, key| hash[key] = [] }
          failures = {}
          stats.keys.each_slice(@rpc.download_batch_size) do |group|
            response = @rpc.call(group, "file_transfer.list #{source}") do |client|
              client.list(path: source, max_bytes: @rpc.message_data_bytes)
            end
            failures.merge!(response.errors)
            response.responded.each do |identity, data|
              entries = data[:entries]
              unless entries.is_a?(Array) && entries.all?(Hash)
                failures[identity] = Outcome.failure(identity, :transfer_failed, "The file_transfer.list call for #{source} on #{identity} answered with an unusable listing")
                next
              end
              odd = entries.find { |entry| !LocalPath.plain_relative_path?(entry[:name]) }
              if odd
                failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} lists #{odd[:name].inspect}, which is not a plain relative path")
                next
              end
              unusable = entries.find { |entry| entry[:type] == 'directory' && !entry[:symlink] && !mode?(entry[:mode]) }
              if unusable
                failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} lists #{unusable[:name].inspect} without a usable mode")
                next
              end

              directories[''][identity] = stats[identity][:mode]
              entries.each do |entry|
                if entry[:type] == 'directory' && entry[:symlink]
                  @logger.warn("Skipping #{File.join(source, entry[:name])} on #{identity}, a symbolic link to a directory")
                elsif entry[:type] == 'directory'
                  directories[entry[:name]][identity] = entry[:mode]
                elsif entry[:type] == 'file'
                  files[entry[:name]] << identity
                else
                  @logger.warn("Skipping #{File.join(source, entry[:name])} on #{identity}, which is not a regular file or directory")
                end
              end
            end
          end
          [directories, files, failures]
        end

        # Creates every listed directory locally for the pending nodes, the
        # root first, each with the permission bits its node reported and
        # the owner's bits added, under the umask, as net-scp makes a
        # downloaded directory, so a tree with a read-only directory can
        # still be written while it lands, and without the setuid, setgid
        # and sticky bits, which the node chose. A node leaves the pending
        # set at the first directory that cannot be made for it.
        #
        # @param directories [Hash{String => Hash{String => String}}] Relative path to the mode
        #   per identity that has it
        # @param destination_dirs [Hash{String => String}] Identity to its local directory
        # @param source [String] The directory on every node
        # @param pending [Array<String>] The nodes still pending
        # @return [Array(Hash{String => String}, Hash{String => Outcome})] The local root per
        #   identity that got one, and the failures
        def create_tree_directories(directories, destination_dirs, source, pending)
          roots = {}
          failures = {}
          directories.each do |relative, modes|
            (modes.keys & (pending - failures.keys)).each do |identity|
              local = tree_path_for(identity, destination_dirs, source, relative)
              begin
                # Whatever is missing above the directory is this host's
                # own, the node's directory included, so it is made under
                # the umask alone before the listed directory gets its
                # node's mode, which mkdir_p would otherwise give the
                # parents too.
                FileUtils.mkdir_p(File.dirname(local))
                FileUtils.mkdir_p(local, mode: ((modes[identity].to_i(8) & 0o777) | 0o700) & ~File.umask)
              rescue SystemCallError => e
                failures[identity] = Outcome.failure(identity, :transfer_failed, "#{local} could not be created for #{identity}: #{e.class}: #{e.message}")
                next
              end
              roots[identity] ||= local
            end
          end
          [roots, failures]
        end

        # Receives every listed file from the pending nodes that listed it.
        # Returns the failures.
        #
        # @param files [Hash{String => Array<String>}] Relative path to the identities that
        #   have it
        # @param source [String] The directory on every node
        # @param destination_dirs [Hash{String => String}] Identity to its local directory
        # @param pending [Array<String>] The nodes still pending
        # @return [Hash{String => Outcome}]
        def fetch_tree_files(files, source, destination_dirs, pending)
          failures = {}
          files.each do |relative, group|
            entry_source = File.join(source, relative)
            group &= pending - failures.keys
            next if group.empty?

            stats, stat_failures = stat_sources(group, entry_source)
            failures.merge!(stat_failures)
            # The listing said file, so anything else now is the node's
            # problem. Only a file description carries the size and digest
            # that the download needs.
            changed = stats.reject { |_identity, data| data[:type] == 'file' }.keys
            failures.merge!(Outcome.failures(changed, :transfer_failed) { |identity| "#{entry_source} on #{identity} was listed as a file and is no longer one" })
            stats = stats.except(*changed)
            next if stats.empty?

            destinations = stats.keys.to_h { |identity| [identity, tree_path_for(identity, destination_dirs, source, relative)] }
            _placed, file_failures = fetch_files(entry_source, stats, destinations)
            failures.merge!(file_failures)
          end
          failures
        end

        # Returns the local path for one entry of a downloaded tree. Every
        # component of it is a plain name, the source's by the check in run
        # and the entries' by the check in list_trees.
        #
        # @param identity [String]
        # @param destination_dirs [Hash{String => String}] Identity to its local directory
        # @param source [String] The directory on every node
        # @param relative [String] The entry's path relative to the source, empty for the root
        # @return [String]
        def tree_path_for(identity, destination_dirs, source, relative)
          base = File.join(destination_dirs[identity], LocalPath.last_component(source))
          relative.empty? ? base : File.join(base, relative)
        end
      end
    end
  end
end
