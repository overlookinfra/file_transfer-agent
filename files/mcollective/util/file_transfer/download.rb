# frozen_string_literal: true

require 'fileutils'
require_relative 'local_path'
require_relative 'outcome'
require_relative 'receiver'
require_relative 'rpc'

module MCollective
  module Util
    module FileTransfer
      # One download from every node to this host. run is the whole lifecycle
      # and returns an Outcome per node. It stats the source with a checksum
      # on every node and fetches each file through the Receiver, which
      # assembles every copy beside its destination. For a tree it lists the
      # tree on every node, then makes or fetches each listed path for the
      # nodes that listed it. Each step takes the nodes still pending and
      # returns the failures among them. Reads no chunks itself.
      class Download
        # @param rpc [Rpc]
        # @param logger [#debug, #info, #warn, #error]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
          @receiver = Receiver.new(rpc: rpc, logger: logger)
        end

        # Fetches the source from every node into that node's directory, under
        # the source's own name. The name is checked before any call and the
        # stat on every node comes before any write, so a node the controller
        # can tell is hopeless gets nothing.
        #
        # @param source [String] The path on every node, valid UTF-8
        # @param destination_dirs [Hash{String => String}] Identity to the local directory that
        #   receives its copy, each valid UTF-8
        # @return [Hash{String => Outcome}] By identity
        def run(source, destination_dirs)
          identities = destination_dirs.keys
          # The copies are written under the source's name, so a name that is not
          # one plain component fails every node before any call.
          name = LocalPath.last_component(source)
          unless LocalPath.plain_name?(name)
            return Outcome.failures(identities, :transfer_failed) do |identity|
              "The source name #{name.inspect} is not a plain file name, so #{source} cannot be placed for #{identity}"
            end
          end

          # Every copy is written under the source's name in its node's directory,
          # a file at that path and a tree with that path as its root.
          destinations = destination_dirs.transform_values { |directory| File.join(directory, name) }
          descriptions, failures = describe_source(identities, source)
          # Each node's own directory is this host's, made under the umask
          # alone once the stat says the node has something to give.
          descriptions.each_key do |identity|
            FileUtils.mkdir_p(destination_dirs[identity])
          rescue SystemCallError => e
            failures[identity] = Outcome.failure(identity, :transfer_failed,
              "#{destination_dirs[identity]} could not be created for #{identity}: #{e.class}: #{e.message}")
          end
          files, trees = descriptions.except(*failures.keys).partition { |_identity, description| description[:type] == 'file' }.map(&:to_h)
          failures.merge!(fetch_file(source, files, destinations.slice(*files.keys)))
          failures.merge!(fetch_tree(source, trees, destinations.slice(*trees.keys)))
          # Only the nodes that answered the stat have a path, so a node with
          # neither a failure nor a description raises in per_identity, as it should.
          Outcome.per_identity(identities, failures, destinations.slice(*descriptions.keys))
        end

        private

        # Stats with checksum. Anything but a file or directory fails its node.
        #
        # @param identities [Array<String>] The nodes to ask
        # @param source [String] The path on every node
        # @return [Array(Hash{String => Hash}, Hash{String => Outcome})] The description per
        #   identity that can be read from, and the failures
        def describe_source(identities, source)
          response = @rpc.call(identities, "file_transfer.stat #{source}") { |client| client.stat(path: source, checksum: true) }
          failures = response.errors.dup
          descriptions = {}
          response.responded.each do |identity, description|
            if !description[:exists]
              failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} does not exist on #{identity}")
            elsif !['file', 'directory'].include?(description[:type])
              failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} is not a regular file or directory")
            elsif !usable?(description)
              failures[identity] = Outcome.failure(identity, :transfer_failed,
                "#{source} on #{identity} was described without a usable #{needed_fields(description[:type])}")
            else
              descriptions[identity] = description
            end
          end
          [descriptions, failures]
        end

        # Whether a stat reply contains the copy's mode, and for a file the
        # size the rounds stop at and the digest to verify against. The node
        # decides what the reply says, so each is checked before it is used.
        #
        # @param data [Hash] The stat reply data
        # @return [Boolean]
        def usable?(data)
          return false unless mode?(data[:mode])
          return true unless data[:type] == 'file'

          data[:size].is_a?(Integer) && !data[:size].negative? && data[:sha256].is_a?(String)
        end

        # Whether a value is 3 or 4 octal digits, as the agent reports a mode.
        #
        # @param value [Object] A mode as a node reported it
        # @return [Boolean]
        def mode?(value)
          value.is_a?(String) && value.match?(/\A[0-7]{3,4}\z/)
        end

        # The fields of a stat or listing entry that the download depends on.
        #
        # @param type [String] file or directory
        # @return [String]
        def needed_fields(type)
          type == 'file' ? 'size, digest and mode' : 'mode'
        end

        # Receives one remote file from the identities in destinations and
        # places each verified copy at its identity's local path, whose
        # directory exists. A directory already at a destination fails its
        # node rather than taking the file inside.
        #
        # @param source [String] The path on every node
        # @param descriptions [Hash{String => Hash}] Identity to its description
        # @param destinations [Hash{String => String}] Identity to the local path its copy ends up at
        # @return [Hash{String => Outcome}] The failures
        def fetch_file(source, descriptions, destinations)
          failures = {}
          destinations.each do |identity, destination|
            next unless File.directory?(destination)

            failures[identity] = Outcome.failure(identity, :transfer_failed, "#{destination} is a directory, so the download from #{identity} was not placed there")
          end
          failures.merge(@receiver.receive_file(source, descriptions, destinations.except(*failures.keys)))
        end

        # Downloads the tree under the source from the nodes in descriptions.
        # It asks every node for its listing, makes each node's root, then
        # makes or fetches each listed path for the nodes that listed it. A
        # node leaves at its first failure.
        #
        # @param source [String] The directory on every node
        # @param descriptions [Hash{String => Hash}] Identity to its description, for the nodes
        #   where the source is a directory
        # @param roots [Hash{String => String}] Identity to the local root of its tree
        # @return [Hash{String => Outcome}] The failures
        def fetch_tree(source, descriptions, roots)
          listed, failures = list_source(descriptions.keys, source)
          # The listing starts below the root, so the root is made first, with
          # the mode its description reported.
          failures.merge!(create_directory(descriptions, roots.except(*failures.keys)))
          listed.each do |relative, per_node|
            group = per_node.keys - failures.keys
            next if group.empty?

            destinations = group.to_h { |identity| [identity, File.join(roots[identity], relative)] }
            # Nodes can list the same path as different types, so each node's
            # entry decides for that node.
            directories, files = group.partition { |identity| per_node[identity][:type] == 'directory' }
            failures.merge!(create_directory(per_node, destinations.slice(*directories)))
            failures.merge!(fetch_file(File.join(source, relative), per_node, destinations.slice(*files)))
          end
          failures
        end

        # Asks every node for everything under the source, which the agent
        # lists in one reply, parents first, each entry by its relative path
        # and each regular file with its size, digest and mode. A round of
        # nodes at a time, since a reply may be as large as the message data
        # size. A node whose tree lists larger, or whose listing can't be
        # used, fails before anything is written for it. A linked directory
        # comes without its contents and is skipped with a warning, like
        # anything that is neither a file nor a directory. The listings are
        # merged by path, so each path is made or fetched once for every node
        # that listed it.
        #
        # @param identities [Array<String>] The nodes to ask
        # @param source [String] The directory on every node
        # @return [Array(Hash{String => Hash{String => Hash}}, Hash{String => Outcome})] Relative
        #   path to the entry per identity that listed it, in listing order, and the failures
        def list_source(identities, source)
          listed = Hash.new { |hash, key| hash[key] = {} }
          failures = {}
          identities.each_slice(Rpc::DOWNLOAD_BATCH_SIZE) do |group|
            response = @rpc.call(group, "file_transfer.list #{source}") do |client|
              client.list(path: source, max_bytes: @rpc.message_data_bytes, checksum: true)
            end
            failures.merge!(response.errors)
            response.responded.each do |identity, data|
              failure = listing_failure(identity, source, data[:entries])
              if failure
                failures[identity] = failure
                next
              end

              data[:entries].each do |entry|
                if entry[:type] == 'directory' && entry[:symlink]
                  @logger.warn("Skipping #{File.join(source, entry[:name])} on #{identity}, a symbolic link to a directory")
                elsif ['file', 'directory'].include?(entry[:type])
                  listed[entry[:name]][identity] = entry
                else
                  @logger.warn("Skipping #{File.join(source, entry[:name])} on #{identity}, which is not a regular file or directory")
                end
              end
            end
          end
          [listed, failures]
        end

        # Why a listing can't be used, or nil when every entry can. Each entry
        # comes from the node and is checked. The listing must be entries, each
        # path plain components all the way down, and each entry must contain
        # the fields the download depends on. A file the node could not read
        # fails the node with the agent's reason. Each such file is named in a
        # warning, since the outcome names only the first.
        #
        # @param identity [String] The node that answered
        # @param source [String] The directory on every node
        # @param entries [Object] The entries of the reply
        # @return [Outcome, nil]
        def listing_failure(identity, source, entries)
          unless entries.is_a?(Array) && entries.all?(Hash)
            return Outcome.failure(identity, :transfer_failed, "The file_transfer.list call for #{source} on #{identity} answered with an unusable listing")
          end

          odd = entries.find { |entry| !LocalPath.plain_relative_path?(entry[:name]) }
          return Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} lists #{odd[:name].inspect}, which is not a plain relative path") if odd

          unreadable = entries.select { |entry| entry[:type] == 'file' && entry[:error] }
          unless unreadable.empty?
            unreadable.each { |entry| @logger.warn("#{File.join(source, entry[:name])} on #{identity} could not be read for its digest: #{entry[:error]}") }
            return Outcome.failure(identity, :transfer_failed,
              "#{File.join(source, unreadable.first[:name])} on #{identity} could not be read for its digest: #{unreadable.first[:error]}")
          end

          unusable = entries.find do |entry|
            case entry[:type]
            when 'directory' then !entry[:symlink] && !mode?(entry[:mode])
            when 'file' then !usable?(entry)
            end
          end
          return unless unusable

          Outcome.failure(identity, :transfer_failed,
            "#{source} on #{identity} lists #{unusable[:name].inspect} without a usable #{needed_fields(unusable[:type])}")
        end

        # Makes a directory for each node with the mode it reported. What is
        # above it exists already, the node directory for a root and the
        # parent a listing names before its contents, so the mode goes to the
        # directory alone.
        #
        # @param descriptions [Hash{String => Hash}] Identity to its description, which contains the mode
        # @param destinations [Hash{String => String}] Identity to the local directory to make
        # @return [Hash{String => Outcome}] The failures
        def create_directory(descriptions, destinations)
          failures = {}
          destinations.each do |identity, destination|
            FileUtils.mkdir_p(destination, mode: Receiver.local_mode(descriptions[identity][:mode], 0o700))
          rescue SystemCallError => e
            failures[identity] = Outcome.failure(identity, :transfer_failed, "#{destination} could not be created for #{identity}: #{e.class}: #{e.message}")
          end
          failures
        end
      end
    end
  end
end
