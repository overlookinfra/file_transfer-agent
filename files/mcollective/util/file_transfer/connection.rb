# frozen_string_literal: true

require 'mcollective'

module MCollective
  module Util
    module FileTransfer
      # Raised by a guarded connection before a message larger than the
      # broker's limit reaches the socket. The broker would otherwise close
      # the connection and the caller would only see missing replies.
      class PayloadTooLarge < StandardError
        def initialize(size, limit)
          super("A #{size} byte message exceeds the broker's #{limit} byte payload limit")
        end
      end

      # Builds one RPC client per call from an options hash, the way an mco
      # application does, lets only one call run at a time, and refuses any
      # message larger than the broker's limit before it is sent. The limit
      # is one value for the whole process, set for as long as the call
      # that set it runs, so a second call running alongside would have its
      # messages checked against the first call's limit or none. A caller
      # whose process serializes its other RPC calls with a lock of its own,
      # as OpenBolt does, passes that lock as the mutex and the options its
      # clients use.
      class Connection
        # Prepended onto the NATS wrapper class, the one object every
        # request in the process is published through.
        module PublishGuard
          class << self
            attr_accessor :limit
          end

          def publish(destination, payload, reply = nil)
            limit = PublishGuard.limit
            raise PayloadTooLarge.new(payload.bytesize, limit) if limit && payload.bytesize > limit

            super
          end
        end
        private_constant :PublishGuard

        # @param options [Hash] The client options, Util.default_options by default
        # @param mutex [Mutex] The lock every call runs under, a caller's own when its process
        #   has other RPC calls to serialize with
        def initialize(options = Util.default_options, mutex: Mutex.new)
          @options = options
          @mutex = mutex
        end

        # Yields an RPC client for the agent that addresses the identities
        # directly, without discovery.
        #
        # @param timeout [Numeric] Seconds to wait for the replies
        # @param publish_timeout [Numeric, nil] Seconds allowed for publishing the request to
        #   every identity. When given, publishing is unthreaded so that an exception raised
        #   while publishing reaches the caller instead of dying in a publisher thread.
        # @return [Object] Whatever the block returns
        def with_client(agent, identities, timeout:, publish_timeout:)
          @mutex.synchronize do
            options = @options.merge(verbose: false)
            if publish_timeout
              options[:publish_timeout] = publish_timeout
              options[:threaded] = false
            end
            client = RPC::Client.new(agent, options: options)
            # Set after the build, which replaces a timeout of exactly 5,
            # the gem's default, with the DDL timeout plus the discovery
            # timeout. Every request carries the client's value at call time.
            client.timeout = timeout
            client.progress = false
            client.discover(nodes: identities)
            yield(client)
          end
        end

        # Runs the block with every message it publishes held under the
        # limit, raising PayloadTooLarge for one over it before the socket.
        # For the block of with_client, where the client that publishes is
        # built and the lock is held. Ruby prepends a module once, so the
        # wrapper class is only changed by the first call.
        #
        # @param limit [Integer] The broker's payload limit in bytes
        # @return [Object] Whatever the block returns
        def guard(limit)
          nats_wrapper.class.prepend(PublishGuard)
          PublishGuard.limit = limit
          yield
        ensure
          PublishGuard.limit = nil
        end

        # The payload limit the broker advertised when the wrapper's client
        # connected, as the server info states it, or nil before that
        # connection, since the server info arrives with it. The wrapper
        # keeps its client to itself, so this reads the instance variable.
        #
        # @return [Object] The advertised value, an Integer from a real broker
        def max_payload
          nats_wrapper.instance_variable_get(:@client).server_info[:max_payload]
        end

        private

        # The NATS wrapper every request is published through. The connector
        # is a process-wide singleton, so this is the same object for every
        # RPC client. Raises when no connector plugin is loaded.
        def nats_wrapper
          PluginManager['connector_plugin'].connection
        end
      end
    end
  end
end
