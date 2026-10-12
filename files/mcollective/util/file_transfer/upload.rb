# frozen_string_literal: true

require 'find'
require 'pathname'
require_relative 'local_path'
require_relative 'outcome'
require_relative 'sender'

module MCollective
  module Util
    module FileTransfer
      # One upload: what happened to each node. run is the whole lifecycle:
      # where the source lands, every file through the Sender, one Outcome
      # per node. Each step takes the nodes still pending and answers the
      # failures among them.
      class Upload
        # @param rpc [Rpc]
        # @param logger [#debug, #warn]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
          @sender = Sender.new(rpc: rpc, logger: logger)
        end

        # See Client#upload. The destination is resolved before anything is
        # sent, so a request that the controller can tell is hopeless sends
        # nothing.
        #
        # @param source [String] A local file or directory, valid UTF-8
        # @param destination [String] The path on every node, valid UTF-8
        # @param identities [Array<String>] The nodes to send to
        # @return [Hash{String => Outcome}] By identity
        # @raise [SystemCallError] When the source cannot be read
        def run(source, destination, identities)
          stat = File.stat(source)
          destinations, failures = resolve_destinations(source, destination, identities, directory: stat.directory?)
          failures.merge!(deliver(source, destinations, directory: stat.directory?))
          Outcome.per_identity(identities, failures, destinations)
        end

        private

        # Where the upload lands on each node, from one stat of the
        # destination. An existing directory receives the source inside it
        # under its own name, like mv would, and a destination ending in a
        # separator names a directory, so a file fails on a node where there
        # is none. The name is the one the source's absolute path ends in,
        # so a source given as . or .. lands under the directory it stands
        # for and a link under its own name. A file's name becomes the last
        # component of its destination on the node, and a tree's lands it,
        # so a name that no path can carry, or that no directory can hold,
        # fails every node without a call, as a tree's entries do.
        #
        # @param source [String] A local file or directory
        # @param destination [String] The path on every node
        # @param identities [Array<String>] The nodes to ask
        # @param directory [Boolean] Whether the source is a directory
        # @return [Array(Hash{String => String}, Hash{String => Outcome})] The path per identity
        #   that resolved, and the failures
        def resolve_destinations(source, destination, identities, directory:)
          name = File.basename(File.absolute_path(source))
          unless LocalPath.plain_name?(name)
            refused = Outcome.failures(identities, :transfer_failed) do |identity|
              "The source name #{name.inspect} is not a plain file name, so #{source} cannot be sent to #{identity}"
            end
            return [{}, refused]
          end

          response = @rpc.call(identities, "file_transfer.stat #{destination}") { |client| client.stat(path: destination) }
          failures = response.errors.dup
          destinations = {}
          response.responded.each do |identity, data|
            if data[:type] == 'directory'
              destinations[identity] = File.join(destination, name)
            elsif !directory && LocalPath.names_directory?(destination)
              failures[identity] = Outcome.failure(identity, :transfer_failed,
                "#{destination} #{data[:exists] ? 'is not a directory' : 'does not exist'} on #{identity}")
            else
              destinations[identity] = destination
            end
          end
          [destinations, failures]
        end

        # Sends the source to the destinations, a file once and a tree entry
        # by entry. Returns the failures.
        #
        # @param source [String] A local file or directory
        # @param destinations [Hash{String => String}] Identity to the path the upload lands at
        # @param directory [Boolean] Whether the source is a directory
        # @return [Hash{String => Outcome}]
        def deliver(source, destinations, directory:)
          return {} if destinations.empty?

          @logger.debug("Upload chunks go to #{@rpc.upload_batch_size} nodes per request")
          directory ? send_tree(source, destinations) : @sender.send_file(source, destinations)
        end

        # Sends every entry of a local directory to the nodes still pending,
        # creating the directories on the nodes and sending the files, until
        # no node is left or an entry cannot be named or read, which fails
        # the pending nodes.
        #
        # @param source [String] The local directory
        # @param destinations [Hash{String => String}] Identity to the directory the tree lands in
        # @return [Hash{String => Outcome}] The failures
        def send_tree(source, destinations)
          pending = destinations
          failures = {}
          unnameable = walk_local_tree(source) do |relative, path, stat|
            entry_destinations = pending.transform_values { |base| relative.empty? ? base : File.join(base, relative) }
            step = if stat.directory?
                     mkdir_remote(entry_destinations, Sender.permission_bits(stat))
                   else
                     @sender.send_file(path, entry_destinations)
                   end
            failures.merge!(step)
            pending = pending.except(*step.keys)
            break if pending.empty?
          end
          if unnameable
            path, reason = unnameable
            failures.merge!(Outcome.failures(pending.keys, :transfer_failed) { "The name of #{path.inspect} #{reason}, so it cannot be sent" })
          end
          failures
        rescue SystemCallError => e
          # A source entry that cannot be read, such as a dangling link.
          failures.merge(Outcome.failures(pending.keys, :transfer_failed) { "Reading #{source} failed: #{e.class}: #{e.message}" })
        end

        # Yields every entry of a local tree, parents before their contents,
        # in the order Find lists them, with its path relative to the source,
        # empty for the source itself, its local path and its stat. The name
        # checks come first, since no relative path can be made from a name
        # that is not valid UTF-8. An entry whose name is not valid in its
        # encoding, or not a plain file name, ends the walk and comes back
        # with the reason. A symbolic link to a file is sent as the file it
        # points at. Find does not descend into a symbolic link to a
        # directory, and the walk skips it with a warning, so it cannot
        # loop. The source itself is resolved first, so a link to a
        # directory can still be the source.
        #
        # @param source [String] The local directory
        # @yieldparam relative [String] The entry's path relative to the source, empty for
        #   the source itself
        # @yieldparam path [String] The entry's local path
        # @yieldparam stat [File::Stat] The entry's stat
        # @return [Array(String, String), nil] The path and the reason of the entry that ended
        #   the walk, or nil after a complete walk
        def walk_local_tree(source)
          root = LocalPath.as_utf8(File.realpath(source))
          Find.find(root, ignore_error: false) do |path|
            return [path, "is not valid #{path.encoding}"] unless path.valid_encoding?
            return [path, 'is not a plain file name'] unless path == root || LocalPath.plain_name?(File.basename(path))

            if File.symlink?(path) && File.directory?(path)
              @logger.warn("Skipping #{path}, a symbolic link to a directory")
              next
            end

            relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
            yield(relative == '.' ? '' : relative, path, File.stat(path))
          end
          nil
        end

        # One mkdir per distinct remote path, since a call carries one set
        # of arguments to every node. Returns the failures.
        #
        # @param destinations [Hash{String => String}] Identity to the directory path on it
        # @param mode [String] Four octal digits
        # @return [Hash{String => Outcome}]
        def mkdir_remote(destinations, mode)
          failures = {}
          destinations.group_by { |_identity, path| path }.each do |path, pairs|
            identities = pairs.map(&:first)
            response = @rpc.call(identities, "file_transfer.mkdir #{path}") { |client| client.mkdir(path: path, mode: mode) }
            failures.merge!(response.errors)
          end
          failures
        end
      end
    end
  end
end
