# frozen_string_literal: true

require 'find'
require 'pathname'
require_relative 'local_path'
require_relative 'outcome'
require_relative 'sender'

module MCollective
  module Util
    module FileTransfer
      # One upload of a file or tree from this host to every node. run is the
      # whole lifecycle and returns an Outcome per node. It resolves each
      # node's destination and sends every file through the Sender. Each step
      # takes the nodes still pending and returns the failures among them.
      class Upload
        # @param rpc [Rpc]
        # @param logger [#debug, #info, #warn, #error]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
          @sender = Sender.new(rpc: rpc, logger: logger)
        end

        # Sends the source, a file or a tree, to the destination on every node.
        # The destination is resolved first, so a request the controller can
        # tell is hopeless sends nothing.
        #
        # @param source [String] A local file or directory, valid UTF-8
        # @param destination [String] The path on every node, valid UTF-8
        # @param identities [Array<String>] The nodes to send to
        # @return [Hash{String => Outcome}] By identity
        # @raise [SystemCallError] When the source cannot be read
        def run(source, destination, identities)
          stat = File.stat(source)
          name = File.basename(File.absolute_path(source))
          unless LocalPath.plain_name?(name)
            return Outcome.failures(identities, :transfer_failed) do |identity|
              "The source name #{name.inspect} is not a plain file name, so #{source} cannot be sent to #{identity}"
            end
          end

          destinations, failures = resolve_destinations(name, destination, identities, directory: stat.directory?)
          unless destinations.empty?
            @logger.debug("Upload chunks go to #{@rpc.upload_batch_size} nodes per request")
            failures.merge!(stat.directory? ? send_tree(source, destinations) : @sender.send_file(source, stat, destinations))
          end
          Outcome.per_identity(identities, failures, destinations)
        end

        private

        # Where the upload is written on each node, from one stat of the
        # destination. An existing directory receives the source inside it
        # under its name, like mv would. A destination ending in a separator
        # names a directory, so a file fails on a node where there is none.
        #
        # @param name [String] The source's own name
        # @param destination [String] The path on every node
        # @param identities [Array<String>] The nodes to ask
        # @param directory [Boolean] Whether the source is a directory
        # @return [Array(Hash{String => String}, Hash{String => Outcome})] The path per identity
        #   that resolved, and the failures
        def resolve_destinations(name, destination, identities, directory:)
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

        # Sends every entry of a local directory to the pending nodes, until
        # none is left or an entry can't be read, which fails the pending ones.
        # The whole tree is listed first, so an entry that can't be named fails
        # every node before anything is sent.
        #
        # @param source [String] The local directory
        # @param destinations [Hash{String => String}] Identity to the directory the tree is written to
        # @return [Hash{String => Outcome}] The failures
        def send_tree(source, destinations)
          pending = destinations
          failures = {}
          entries, unnameable = walk_local_tree(source)
          if unnameable
            path, reason = unnameable
            return Outcome.failures(pending.keys, :transfer_failed) { "The name of #{path.inspect} #{reason}, so it cannot be sent" }
          end

          entries.each do |relative, path, stat|
            entry_destinations = pending.transform_values { |base| relative.empty? ? base : File.join(base, relative) }
            step = if stat.directory?
                     mkdir_remote(entry_destinations, Sender.permission_bits(stat))
                   else
                     @sender.send_file(path, stat, entry_destinations)
                   end
            failures.merge!(step)
            pending = pending.except(*step.keys)
            break if pending.empty?
          end
          failures
        rescue SystemCallError => e
          # A source entry that can't be read, such as a directory the walk
          # can't list.
          failures.merge(Outcome.failures(pending.keys, :transfer_failed) { "Reading #{source} failed: #{e.class}: #{e.message}" })
        end

        # Lists every entry of a local tree in Find's order, parents first, each
        # as its path relative to the source, empty for the source itself, its
        # local path and its stat. Names are checked first, since no relative
        # path can be made from one that is not valid UTF-8. An entry whose name
        # is invalid in its encoding or not a plain file name ends the walk and
        # is returned with the reason. A link to a file is listed as its target.
        # Find doesn't descend into a link to a directory, which the walk skips
        # with a warning, so it can't loop. A named pipe, a dangling link or
        # anything else that is not a regular file or directory is also skipped
        # with a warning, as a download skips one. The source is resolved first,
        # so it may be a link to a directory.
        #
        # @param source [String] The local directory
        # @return [Array(Array<Array(String, String, File::Stat)>, Array(String, String))] The
        #   entries and nil, or nil and the path and reason of the entry that ended the walk
        def walk_local_tree(source)
          root = LocalPath.as_utf8(File.realpath(source))
          entries = []
          Find.find(root, ignore_error: false) do |path|
            return [nil, [path, "is not valid #{path.encoding}"]] unless path.valid_encoding?
            return [nil, [path, 'is not a plain file name']] unless path == root || LocalPath.plain_name?(File.basename(path))

            if File.symlink?(path) && File.directory?(path)
              @logger.warn("Skipping #{path}, a symbolic link to a directory")
              next
            end

            # A dangling link has no stat to follow, so it's skipped like a
            # download skips one, which the agent lists as type other.
            stat = begin
              File.stat(path)
            rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
              nil
            end
            unless stat&.file? || stat&.directory?
              @logger.warn("Skipping #{path}, which is not a regular file or directory")
              next
            end

            relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
            entries << [relative == '.' ? '' : relative, path, stat]
          end
          [entries, nil]
        end

        # One mkdir per path, since a call sends every node the same arguments.
        #
        # @param destinations [Hash{String => String}] Identity to the directory path on it
        # @param mode [String] 4 octal digits
        # @return [Hash{String => Outcome}] The failures
        def mkdir_remote(destinations, mode)
          failures = {}
          destinations.keys.group_by { |identity| destinations[identity] }.each do |path, identities|
            response = @rpc.call(identities, "file_transfer.mkdir #{path}") { |client| client.mkdir(path: path, mode: mode) }
            failures.merge!(response.errors)
          end
          failures
        end
      end
    end
  end
end
