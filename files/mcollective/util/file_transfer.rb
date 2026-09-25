# frozen_string_literal: true

require_relative 'file_transfer/connection'
require_relative 'file_transfer/default_logger'
require_relative 'file_transfer/download'
require_relative 'file_transfer/file_sender'
require_relative 'file_transfer/rpc'
require_relative 'file_transfer/session'
require_relative 'file_transfer/sizing'
require_relative 'file_transfer/transfer'
require_relative 'file_transfer/upload'

module MCollective
  module Util
    # The client side of the file_transfer agent. A Client moves files to
    # and from nodes in chunks sized to the broker's payload limit, verifies
    # every file with SHA-256, and keeps temporary files in sessions the
    # agent owns. Nodes are addressed by Choria identity, and every call
    # answers an Outcome per identity rather than raising for one node's
    # failure. The README describes the connection and logger contracts.
    module FileTransfer
      VERSION = '1.0.0'

      class Client
        # @param connection [Connection] Builds the RPC clients from a caller's options and lock
        # @param logger [#debug, #warn, #warn_once] Receives the log lines, see DefaultLogger
        # @param rpc_timeout [Numeric] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node. A call that digests a whole file on the node waits
        #   the agent's DDL timeout instead when that is longer.
        # @param chunk_size [Integer, nil] The most file content one request carries, or nil to let
        #   the sizing calculation decide
        # @param upload_batch_size [Integer, nil] How many nodes one chunk request is published to
        #   at once, or nil for as many as we can to keep a batch under Sizing::UPLOAD_BATCH_BYTES
        # @param download_batch_size [Integer, nil] How many nodes one download round asks at once,
        #   or nil for as many as we can to keep one round of replies under the broker's connection backlog
        # @param cleanup [Boolean, Hash{String => Boolean}] Whether sessions are removed
        #   afterwards, for every node or per identity
        def initialize(connection:, logger: DefaultLogger.new, rpc_timeout: 30, chunk_size: nil,
                       upload_batch_size: nil, download_batch_size: nil, cleanup: true)
          @logger = logger
          @rpc = Rpc.new(connection, logger, rpc_timeout)
          @sizing = Sizing.new(connection, logger, chunk_size: chunk_size, upload_batch_size: upload_batch_size,
            download_batch_size: download_batch_size)
          @cleanup = cleanup
        end

        # Sends a local file or directory tree to the same destination on
        # every node.
        #
        # @param source [String] A local file or directory
        # @param destination [String] The path on every node. An existing directory receives
        #   the file or tree inside it, like mv would.
        # @return [Hash{String => Outcome}] By identity, with success being the path the file landed at
        def upload(source, destination, identities)
          transfer = start_transfer(identities)
          Upload.new(transfer: transfer, rpc: @rpc, sizing: @sizing, logger: @logger, cleanup: @cleanup).run(source, destination)
        end

        # Fetches a file or directory tree from every node into a local
        # directory per node.
        #
        # @param source [String] The path on every node
        # @param destinations [Hash{String => String}] Identity to the local directory that
        #   receives its copy, named after the source's basename
        # @return [Hash{String => Outcome}] By identity, with success being the local path
        def download(source, destinations)
          transfer = start_transfer(destinations.keys)
          Download.new(transfer: transfer, rpc: @rpc, sizing: @sizing, logger: @logger).run(source, destinations)
        end

        # A session on every identity, for files a caller delivers and
        # removes itself. The identities whose mktemp failed are in the
        # session's failures.
        def open_session(identities)
          transfer = start_transfer(identities)
          sender = FileSender.new(transfer: transfer, rpc: @rpc, sizing: @sizing, logger: @logger)
          Session.create(transfer: transfer, rpc: @rpc, logger: @logger, cleanup: @cleanup, sender: sender)
        end

        private

        # A transfer to the identities, logged with the sizing it runs under.
        def start_transfer(identities)
          transfer = Transfer.new(identities)
          @logger.debug("File transfer with #{transfer.count} has #{@sizing.summary}")
          transfer
        end
      end
    end
  end
end
