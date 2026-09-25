# frozen_string_literal: true

require 'find'
require 'pathname'
require_relative 'file_sender'
require_relative 'outcome'
require_relative 'session'

module MCollective
  module Util
    module FileTransfer
      # Sending a file or a tree to the same destination on every node,
      # each file through a FileSender inside one session for the transfer.
      class Upload
        # @param transfer [Transfer] The nodes to send to, which drop out as steps fail
        # @param rpc [Rpc]
        # @param chunk [Integer] The bytes of file content one put carries
        # @param logger [#debug, #warn]
        # @param cleanup [Boolean, Hash{String => Boolean}] Whether the session is removed afterwards
        def initialize(transfer:, rpc:, chunk:, logger:, cleanup:)
          @transfer = transfer
          @rpc = rpc
          @logger = logger
          @cleanup = cleanup
          @sender = FileSender.new(transfer: transfer, rpc: rpc, chunk: chunk, logger: logger)
        end

        # See Client#upload.
        def run(source, destination)
          @logger.debug("Upload chunks go to #{@rpc.upload_batch_size} nodes per request")
          landing = landing_paths(source, destination)
          Session.with(transfer: @transfer, rpc: @rpc, logger: @logger, cleanup: @cleanup, sender: @sender) do |session|
            if File.directory?(source)
              upload_tree(session.id, source, landing)
            else
              @sender.send_file(session.id, source, File.basename(source), landing)
            end
          rescue SystemCallError => e
            # A source entry that cannot be read, such as a dangling link.
            @transfer.fail(Outcome.failures(@transfer.active, :transfer_failed) { "Reading #{source} failed: #{e.class}: #{e.message}" })
          end
          @transfer.outcomes { |identity| landing[identity] }
        end

        private

        # Where the upload lands on each node.
        def landing_paths(source, destination)
          response = @rpc.call(@transfer.active, "file_transfer.stat #{destination}") { |client| client.stat(path: destination) }
          @transfer.fail(response.errors)
          response.responded.to_h do |identity, data|
            [identity, data[:type] == 'directory' ? File.join(destination, File.basename(source)) : destination]
          end
        end

        def upload_tree(session_id, source, landing)
          walk_local_tree(source) do |relative, local_path, stat|
            break unless @transfer.active?

            remote = landing.transform_values { |base| relative.empty? ? base : File.join(base, relative) }
            if stat.directory?
              mkdir_remote(remote, FileSender.permission_bits(stat))
            else
              @sender.send_file(session_id, local_path, relative, remote)
            end
          end
        end

        # Yields every entry of a local tree, parents before their contents,
        # in the order Find lists them. A symbolic link to a file is sent as
        # the file it points at. Find does not descend into a symbolic link
        # to a directory, and the walk skips it with a warning, so it cannot
        # loop. The source itself is resolved first, so a link to a
        # directory can still be the source.
        def walk_local_tree(source)
          root = File.realpath(source)
          Find.find(root, ignore_error: false) do |path|
            if File.symlink?(path) && File.directory?(path)
              @logger.warn("Skipping #{path}, a symbolic link to a directory")
              next
            end

            relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
            yield(relative == '.' ? '' : relative, path, File.stat(path))
          end
        end

        # One mkdir per distinct remote path, since a call carries one set
        # of arguments to every node.
        def mkdir_remote(remote, mode)
          remote.slice(*@transfer.active).group_by { |_identity, path| path }.each do |path, pairs|
            identities = pairs.map(&:first)
            response = @rpc.call(identities, "file_transfer.mkdir #{path}") { |client| client.mkdir(path: path, mode: mode) }
            @transfer.fail(response.errors)
          end
        end
      end
    end
  end
end
