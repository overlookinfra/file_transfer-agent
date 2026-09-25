# frozen_string_literal: true

require 'json'
require 'mcollective'

module MCollective
  module Util
    module FileTransfer
      # Builds one RPC client per call from an options hash, the way an mco
      # application does, and lets only one call run at a time. PublishHook,
      # which refuses any outgoing message larger than the broker's size
      # limit before it is sent, keeps that limit in one place shared by
      # every call in the process for as long as the call that set it runs,
      # so a second call running alongside would have its messages checked
      # against the first call's limit or none. A caller whose process
      # serializes its other RPC calls with a lock of its own, as OpenBolt
      # does, passes that lock as the mutex and the options its clients use.
      class Connection
        # The lengths of one direct request: the signed request, which the
        # connector base64 encodes, and the transport message it publishes
        # with that encoding inside.
        Request = Data.define(:signed_bytes, :wire_bytes)

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

        # The NATS wrapper every request is published through, or nil when
        # the connector does not expose one. The connector is a process-wide
        # singleton, so this is the same object for every RPC client. Raises
        # when no connector plugin is loaded at all.
        #
        # @return [MCollective::Util::NatsWrapper, nil]
        def nats_wrapper
          connector = PluginManager['connector_plugin']
          connector.respond_to?(:connection) ? connector.connection : nil
        end

        # The payload limit the broker advertised when the wrapper's client
        # connected, as the server info states it. The wrapper keeps that
        # client to itself, so this reads the instance variable. Raises
        # when there is no wrapper or no client.
        #
        # @return [Object] The advertised value, an Integer from a real broker
        def max_payload
          nats_wrapper.instance_variable_get(:@client).server_info[:max_payload]
        end

        # The lengths of one direct request for the action to the identity,
        # built like the client and the connector build a request, and never
        # sent. The body, signing, and headers come from the gem's own
        # calls; the sequence mirrors RPC::Client#call_agent and the
        # transport hash mirrors Connector::Nats#publish_connected_directed,
        # so check those two when the gem changes. Used to measure what a
        # chunk request weighs on the wire, so chunks can be sized to the
        # broker's limit.
        #
        # @return [Request]
        def request_bytes(agent, action, args, identity)
          @mutex.synchronize do
            client = RPC::Client.new(agent, options: @options.merge(verbose: false))
            client.progress = false
            options = client.options
            framing = { agent: agent, type: :request, collective: options[:collective], filter: options[:filter], options: options }
            message = Message.new(client.new_request(action, args), nil, framing)
            message.discovered_hosts = [identity]
            message.type = :direct_request
            message.encode!
            signed_bytes = message.payload.bytesize
            message.base64_encode!
            target = PluginManager['connector_plugin'].target_for(message, identity)
            wire = { 'protocol' => 'choria:transport:1', 'data' => message.payload, 'headers' => target[:headers] }.to_json
            Request.new(signed_bytes: signed_bytes, wire_bytes: wire.bytesize)
          end
        end
      end
    end
  end
end
