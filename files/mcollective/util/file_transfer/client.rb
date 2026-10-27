# frozen_string_literal: true

require_relative 'connection'
require_relative 'download'
require_relative 'local_path'
require_relative 'rpc'
require_relative 'upload'

module MCollective
  module Util
    module FileTransfer
      # The gem release after 2.27.0, which honors an explicit threaded false
      # in the client options. The gem's VERSION constant is stale, 2.24.1
      # in the 2.27.0 release, so the check reads the loaded gem's
      # specification instead.
      GEM_REQUIREMENT = Gem::Requirement.new('> 2.27.0')

      # Checks the sizes, reads the caller's paths as UTF-8 and refuses invalid ones, builds
      # the Connection and one Rpc from the caller's options, and starts a new Upload or Download
      # for every call. Makes no RPC call itself.
      class Client
        # The timeout ends a call on a node that never answers, not a healthy
        # transfer. Its default fits a batch of chunk requests on a slow link.
        # It is at least the agent's DDL timeout, within which a node's server
        # stops any request. Every request uses it as its TTL, so a node still
        # accepts a copy a slow link delivers late in the window. The client
        # keeps one chunk request copy per node of an upload batch in memory
        # until it is written. The default batch size keeps those copies under
        # 256 MiB at the broker's limit.
        #
        # @param options [Hash] The gem's client options, as an mco application or OpenBolt
        #   build them
        # @param mutex [Mutex, nil] The lock every call runs under, a caller's own when its
        #   process has other RPC calls to serialize with, or nil for one of this client's own
        # @param logger [#debug, #info, #warn, #error] Receives the log lines at those levels. Default is
        #   MCollective::Log
        # @param rpc_timeout [Integer] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node. Default is 300
        # @param message_data_size [Integer] The data one message contains, in kibibytes, which is
        #   the file content of a chunk and the biggest a directory listing may be. Default is
        #   512, half the broker's 1 MiB limit, which leaves the other half for the envelope and base64
        # @param upload_batch_size [Integer] How many nodes one chunk request is published to at
        #   once. Default is 256, which keeps a batch under 256 MiB
        # @raise [ArgumentError] When the timeout or a size is not an integer above 0
        # @raise [RuntimeError] When the choria-mcorpc-support gem is older than GEM_REQUIREMENT
        def initialize(options, mutex: nil, logger: Log, rpc_timeout: 300, message_data_size: Connection::MAX_PAYLOAD / 1024 / 2,
                       upload_batch_size: 256)
          gem_version = Gem.loaded_specs['choria-mcorpc-support']&.version
          unless gem_version && GEM_REQUIREMENT.satisfied_by?(gem_version)
            raise "The choria-mcorpc-support gem is #{gem_version || 'not loaded through RubyGems'}, and this library needs " \
                  "choria-mcorpc-support #{GEM_REQUIREMENT}"
          end

          # A chunk of 0 bytes would loop a download forever, and a timeout
          # of 0 is no timeout to Ruby.
          { rpc_timeout: rpc_timeout, message_data_size: message_data_size, upload_batch_size: upload_batch_size }.each do |name, value|
            next if value.is_a?(Integer) && value.positive?

            raise ArgumentError, "The #{name} setting must be an integer above 0, not #{value.inspect}"
          end

          @logger = logger
          connection = Connection.new(options, mutex: mutex || Mutex.new)
          @rpc = Rpc.new(connection, logger, rpc_timeout, message_data_bytes: message_data_size * 1024, upload_batch_size: upload_batch_size)
        end

        # Sends a local file or tree to the same destination on every node.
        #
        # @param source [String] A local file or directory
        # @param destination [String] The path on every node. An existing directory receives
        #   the file or tree inside it, like mv would.
        # @param identities [Array<String>] The nodes to send to
        # @return [Hash{String => Outcome}] By identity, with success being the path the file was written to
        # @raise [ArgumentError] When the source name or the destination is not valid UTF-8
        # @raise [SystemCallError] When the source cannot be stat-ed, such as one that does not
        #   exist. A source that can be stat-ed and then not read fails every node in the outcome instead.
        def upload(source, destination, identities)
          source = utf8(source, 'source name')
          destination = utf8(destination, 'destination')
          @logger.info("Upload of #{source} to #{destination} on #{nodes(identities)}")
          Upload.new(rpc: @rpc, logger: @logger).run(source, destination, identities)
        end

        # Fetches a file or tree from each node into its own local directory.
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
          @logger.info("Download of #{source} from #{nodes(destination_dirs.keys)}")
          Download.new(rpc: @rpc, logger: @logger).run(source, destination_dirs)
        end

        private

        # Checks a UTF-8 copy, since a process without a locale passes bytes.
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
