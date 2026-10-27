# frozen_string_literal: true

require 'mcollective'

module MCollective
  module Util
    module FileTransfer
      # Raised by the publish guard before a message larger than the
      # broker's limit reaches the socket. The broker would otherwise close
      # the connection and the caller would only see missing replies.
      class PayloadTooLarge < StandardError
        def initialize(size, limit)
          super("A #{size} byte message exceeds the broker's #{limit} byte payload limit")
        end
      end

      # Builds one RPC client per call from an options hash, as an mco
      # application does. Runs one call at a time and refuses any message
      # over the broker's limit before it is sent. A caller that serializes
      # its other RPC calls with its own lock, as OpenBolt does, passes that
      # lock as the mutex along with its clients' options.
      class Connection
        # The Choria broker's message size limit, nats-server's default,
        # which go-choria has no setting for. Every message is at most this
        # size, and the sizes in Rpc follow from it.
        MAX_PAYLOAD = 1_048_576

        # Prepended onto the NATS wrapper class, the one object every
        # request in the process is published through, since the NATS
        # client checks no sizes itself. From the first call on, every
        # message the process publishes is checked.
        module PublishGuard
          def publish(destination, payload, reply = nil)
            raise PayloadTooLarge.new(payload.bytesize, MAX_PAYLOAD) if payload.bytesize > MAX_PAYLOAD

            super
          end
        end
        private_constant :PublishGuard

        # @param options [Hash] The gem's client options
        # @param mutex [Mutex] The lock every call runs under
        def initialize(options, mutex:)
          @options = options
          @mutex = mutex
        end

        # Yields an RPC client for the agent that addresses the identities
        # directly, without discovery, with the publish guard in place. The
        # timeout is also every request's TTL. A node drops a request older
        # than its TTL, and the last messages of a large batch leave late, so
        # the TTL must cover the whole publish window. On a timeout the
        # controller sends an abort, so a request must not stay valid past it,
        # or a late chunk could arrive after the abort and leave a file behind.
        #
        # @param agent [String] The agent name
        # @param identities [Array<String>] The nodes the client addresses
        # @param timeout [Numeric] Seconds to wait for the replies, allowed for publishing the
        #   request to every identity, and sent with the request as its TTL
        # @param batch_size [Integer, nil] Identities per batch, sent in MCollective's batches
        #   without the pause between them, or nil for all of them at once
        # @yieldparam client [MCollective::RPC::Client] The client for the call
        # @return [Object] Whatever the block returns
        def with_client(agent, identities, timeout:, batch_size: nil)
          @mutex.synchronize do
            # The library addresses every identity given and batches on its own,
            # so it overrides the caller's target limit and batch size here.
            # Publishing is unthreaded, so an exception raised while publishing,
            # such as the publish guard's refusal, reaches the caller instead of
            # being lost in a publisher thread. The gem release after 2.27.0
            # honors that false over the client configuration.
            options = @options.merge(verbose: false, publish_timeout: timeout, ttl: timeout, mcollective_limit_targets: false,
              batch_size: 0, threaded: false)
            client = RPC::Client.new(agent, options: options)
            # Set after the build, which replaces a timeout of exactly 5,
            # the gem's default, with the DDL timeout plus the discovery
            # timeout. Every request is sent with the client's value at call time.
            client.timeout = timeout
            client.progress = false
            client.discover(nodes: identities)
            if batch_size
              client.batch_size = batch_size
              client.batch_sleep_time = 0
            end
            # The connector is a process-wide singleton, so this is the same
            # object for every RPC client, and Ruby prepends a module once,
            # so the class changes on the first call only.
            PluginManager['connector_plugin'].connection.class.prepend(PublishGuard)
            yield(client)
          end
        end
      end
    end
  end
end
