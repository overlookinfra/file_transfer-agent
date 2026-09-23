# frozen_string_literal: true

require 'digest/sha2'
require 'fileutils'
require 'find'
require 'pathname'
require 'securerandom'
require 'tmpdir'
require_relative 'file_transfer/default_logger'
require_relative 'file_transfer/connection'
require_relative 'file_transfer/sizing'
require_relative 'file_transfer/rpc'
require_relative 'file_transfer/transfer'
require_relative 'file_transfer/session'
require_relative 'file_transfer/upload'
require_relative 'file_transfer/download'

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
      AGENT = 'file_transfer'
      # The agent's DDL timeout, the longest a node runs one action.
      DDL_TIMEOUT = 120

      OUTCOME_KINDS = [:no_response, :rpc_error, :rpc_failed, :transfer_failed, :payload_too_large, :checksum_mismatch].freeze
      # A name Windows treats as a device rather than a file, with or
      # without an extension.
      WINDOWS_RESERVED_NAMES = /\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?\z/i

      # What a transfer did for one identity. A success carries the path the
      # file landed at, a failure the kind and a message.
      Outcome = Data.define(:identity, :path, :kind, :message) do
        def self.success(identity, path)
          new(identity: identity, path: path, kind: nil, message: nil)
        end

        def self.failure(identity, kind, message)
          raise ArgumentError, "Unknown outcome kind #{kind.inspect}" unless OUTCOME_KINDS.include?(kind)

          new(identity: identity, path: nil, kind: kind, message: message)
        end

        # One failure per identity, each with the message the block answers
        # for it.
        def self.failures(identities, kind)
          identities.to_h { |identity| [identity, failure(identity, kind, yield(identity))] }
        end

        def success?
          kind.nil?
        end
      end

      # A count of nodes for a log line.
      def self.count(identities)
        size = identities.size
        "#{size} #{size == 1 ? 'node' : 'nodes'}"
      end

      class Client
        attr_reader :rpc, :logger, :chunk_size, :download_group_size

        # @param connection [#with_client, #nats_wrapper] Builds the RPC clients, see Connection
        # @param logger [#debug, #warn, #warn_once] Receives the log lines, see DefaultLogger
        # @param rpc_timeout [Numeric] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node
        # @param chunk_size [Integer, nil] The most file content one request carries, or nil to let
        #   the broker's limit alone decide
        # @param download_group_size [Integer] How many nodes one download round asks at once
        # @param cleanup [Boolean, Hash{String => Boolean}] Whether sessions are removed
        #   afterwards, for every node or per identity
        def initialize(connection:, logger: DefaultLogger.new, rpc_timeout: 30, chunk_size: nil,
                       download_group_size: 32, cleanup: true)
          @rpc = Rpc.new(connection, logger, rpc_timeout)
          @logger = logger
          @chunk_size = chunk_size
          @download_group_size = download_group_size
          @cleanup = cleanup
        end

        # Whether the session on this identity is removed once the transfer
        # is done.
        def cleanup?(identity)
          return @cleanup.fetch(identity, true) if @cleanup.is_a?(Hash)

          @cleanup
        end

        # Sends a local file or directory tree to the same destination on
        # every node.
        #
        # @param source [String] A local file or directory
        # @param destination [String] The path on every node. An existing directory receives
        #   the file or tree inside it, as mv would.
        # @return [Hash{String => Outcome}] By identity, a success carrying the path the file landed at
        def upload(source, destination, identities)
          Upload.new(self).run(source, destination, identities)
        end

        # Fetches a file or directory tree from every node into a local
        # directory per node.
        #
        # @param source [String] The path on every node
        # @param destinations [Hash{String => String}] Identity to the local directory that
        #   receives its copy, named after the source's basename
        # @return [Hash{String => Outcome}] By identity, a success carrying the local path
        def download(source, destinations)
          Download.new(self).run(source, destinations)
        end

        # A session on every identity, for files a caller delivers and
        # removes itself. The identities whose mktemp failed are in the
        # session's failures.
        def open_session(identities)
          Session.create(self, Transfer.start(identities, rpc: @rpc, logger: @logger, chunk_size: @chunk_size))
        end
      end
    end
  end
end
