# frozen_string_literal: true

require_relative 'connection'
require_relative 'default_logger'
require_relative 'download'
require_relative 'local_path'
require_relative 'rpc'
require_relative 'upload'

module MCollective
  module Util
    module FileTransfer
      # The public entry. Checks the sizes, reads the caller's paths as UTF-8
      # and refuses invalid ones, builds the Connection and one Rpc from the
      # caller's options, and starts a new Upload or Download for every
      # call. Makes no RPC call itself.
      class Client
        # @param options [Hash] The gem's client options, as an mco application or OpenBolt
        #   build them
        # @param mutex [Mutex, nil] The lock every call runs under, a caller's own when its
        #   process has other RPC calls to serialize with, or nil for one of this client's own
        # @param logger [#debug, #warn] Receives the log lines, see DefaultLogger
        # @param rpc_timeout [Integer] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node. The wait ends a call on a node that will never answer
        #   rather than bounding a healthy transfer, so the default is long enough for a batch of
        #   chunk requests on a slow link. It is never shorter than the agent's DDL timeout, within
        #   which a node's server stops any request, and every request carries it as its TTL, so
        #   a node still accepts a copy that a slow link delivers late in the window.
        # @param message_data_size [Integer, nil] The data one message carries, in kibibytes, which
        #   is the file content of a chunk and the most a directory listing may weigh, or nil for
        #   512, half the broker's 1 MiB message size limit
        # @param upload_batch_size [Integer, nil] How many nodes one chunk request is published to
        #   at once, or nil for Rpc::UPLOAD_BATCH_SIZE, 256, which keeps a batch under 256 MiB at the broker's limit
        # @raise [ArgumentError] When the timeout or a size is given that is not an integer above zero
        def initialize(options, mutex: nil, logger: DefaultLogger.new, rpc_timeout: 300, message_data_size: nil, upload_batch_size: nil)
          # A chunk of zero bytes would loop a download forever, and a timeout
          # of zero is no timeout at all to Ruby.
          { rpc_timeout: rpc_timeout, message_data_size: message_data_size, upload_batch_size: upload_batch_size }.each do |name, value|
            next if value.nil? || (value.is_a?(Integer) && value.positive?)

            raise ArgumentError, "#{name} must be an integer above zero, not #{value.inspect}"
          end

          @logger = logger
          connection = Connection.new(options, mutex: mutex || Mutex.new)
          @rpc = Rpc.new(connection, logger, rpc_timeout, message_data_kib: message_data_size, upload_batch_size: upload_batch_size)
        end

        # Sends a local file or directory tree to the same destination on
        # every node.
        #
        # @param source [String] A local file or directory
        # @param destination [String] The path on every node. An existing directory receives
        #   the file or tree inside it, like mv would.
        # @param identities [Array<String>] The nodes to send to
        # @return [Hash{String => Outcome}] By identity, with success being the path the file landed at
        # @raise [ArgumentError] When the source name or the destination is not valid UTF-8
        # @raise [SystemCallError] When the source cannot be stat-ed, such as one that does not
        #   exist. A source that can be stat-ed and then not read fails every node in the outcome instead.
        def upload(source, destination, identities)
          source = utf8(source, 'source name')
          destination = utf8(destination, 'destination')
          @logger.debug("Upload of #{source} to #{destination} on #{nodes(identities)}")
          Upload.new(rpc: @rpc, logger: @logger).run(source, destination, identities)
        end

        # Fetches a file or directory tree from every node into a local
        # directory per node.
        #
        # @param source [String] The path on every node
        # @param destination_dirs [Hash{String => String}] Identity to the local directory that
        #   receives its copy, named after the last component of the source
        # @return [Hash{String => Outcome}] By identity, with success being the local path
        # @raise [ArgumentError] When the source name or a destination directory is not valid
        #   UTF-8, before any call to the nodes
        def download(source, destination_dirs)
          source = utf8(source, 'source name')
          destination_dirs = destination_dirs.to_h { |identity, directory| [identity, utf8(directory, "destination directory for #{identity}")] }
          @logger.debug("Download of #{source} from #{nodes(destination_dirs.keys)}")
          Download.new(rpc: @rpc, logger: @logger).run(source, destination_dirs)
        end

        private

        # A caller's path read as UTF-8, which a process without a locale
        # hands over as plain bytes, so the check runs on the retagged copy.
        #
        # @param path [String]
        # @param description [String] Names the path in the error, read after "The"
        # @return [String]
        # @raise [ArgumentError] When the path is not valid UTF-8
        def utf8(path, description)
          path = LocalPath.as_utf8(path)
          raise ArgumentError, "The #{description} #{path.inspect} is not valid #{path.encoding}" unless path.valid_encoding?

          path
        end

        # @param identities [Array<String>]
        # @return [String] The count, such as "1 node" or "3 nodes"
        def nodes(identities)
          "#{identities.size} #{identities.size == 1 ? 'node' : 'nodes'}"
        end
      end
    end
  end
end
