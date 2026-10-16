# frozen_string_literal: true

require 'json'
require 'mcollective'
require 'mcollective/connector/nats'

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
      # clients use. It also puts a cheap base64 check in front of the gem's
      # decode of every received message, and builds the body of a direct
      # request once rather than once per node.
      class Connection
        # Prepended onto the NATS wrapper class, the one object every
        # request in the process is published through. The NATS client
        # checks no sizes, so this is where a request that outgrows the
        # broker's limit is caught, whether the chunk estimate was wrong,
        # a caller set the message data size too high, or the broker
        # allows less than the default.
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

        # Prepended onto the gem's SSL module, whose base64_decode runs a
        # regex over the whole of every received message before decoding
        # it, which costs the client more than everything else it does with
        # a reply. The same check through String#count takes a few hundred
        # microseconds per megabyte. The decode is the one the gem does.
        module Base64Decode
          def base64_decode(string)
            raise(ArgumentError, 'invalid base64') if string.empty? || string.count("^A-Za-z0-9+/= \t\r\n\f\v").positive?

            string.unpack1('m')
          end
        end
        private_constant :Base64Decode

        # Prepended onto the gem's NATS connector, whose direct publish
        # serializes the same message body again for every node it
        # addresses, a few milliseconds per node for a chunk. The body is
        # the payload and the headers, which are the same for every node,
        # so it is built once here and published to each node's subject.
        module DirectPublish
          def publish_connected_directed(msg)
            target = target_for(msg, msg.discovered_hosts.first)
            data = { 'protocol' => 'choria:transport:1', 'data' => msg.payload, 'headers' => target[:headers] }.to_json
            msg.discovered_hosts.each do |node|
              name = make_target(msg.agent, msg.type, msg.collective, node)
              Log.debug("Sending a direct message to #{node} via NATS target '#{name}' for message type #{msg.type}")
              connection.publish(name, data, target[:headers]['reply-to'])
            end
          end
        end
        private_constant :DirectPublish

        # @param options [Hash] The client options, Util.default_options by default
        # @param mutex [Mutex] The lock every call runs under, a caller's own when its process
        #   has other RPC calls to serialize with
        def initialize(options = Util.default_options, mutex: Mutex.new)
          @options = options
          @mutex = mutex
          # Ruby prepends a module once, so a second connection changes nothing.
          SSL.singleton_class.prepend(Base64Decode)
          Connector::Nats.prepend(DirectPublish)
        end

        # Yields an RPC client for the agent that addresses the identities
        # directly, without discovery.
        #
        # @param agent [String] The agent name
        # @param identities [Array<String>] The nodes the client addresses
        # @param timeout [Numeric] Seconds to wait for the replies, which the request carries as
        #   its TTL as well. A node drops a request older than its TTL, and the copies at the end
        #   of a large batch leave the controller last, so a request stays acceptable for as long
        #   as the controller waits for its reply and no longer, which keeps a late chunk ahead
        #   of the abort that follows the wait.
        # @param publish_timeout [Numeric] Seconds allowed for publishing the request to every
        #   identity. Publishing is unthreaded, whatever the options and the client
        #   configuration say, so that an exception raised while publishing reaches the
        #   caller instead of dying in a publisher thread.
        # @yieldparam client [MCollective::RPC::Client] The client for the call
        # @return [Object] Whatever the block returns
        def with_client(agent, identities, timeout:, publish_timeout:)
          @mutex.synchronize do
            # The library addresses the identities it is given and batches
            # on its own, so a target limit or a batch size in the caller's
            # options, mco's --one, --limit-nodes and --batch or a client
            # configuration's default_batch_size, is dropped. The gem would
            # send each call to a random subset of the nodes, or split every
            # call into batches with a sleep between them.
            options = @options.merge(verbose: false, publish_timeout: publish_timeout, ttl: timeout, mcollective_limit_targets: false,
              batch_size: 0)
            client = RPC::Client.new(agent, options: options)
            # The gem ORs this option with the client configuration and has
            # no setter, so a configuration of true would win and the publish
            # guard's refusal would be lost in the publisher thread. Forced
            # off until threading is revisited.
            client.instance_variable_set(:@threaded, false)
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
