# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # The NATS wrapper every request is published through, or nil when
      # the connector does not expose one. The connector is a process-wide
      # singleton, so this is the same object for every RPC client. Raises
      # when no connector plugin is loaded at all.
      #
      # @return [MCollective::Util::NatsWrapper, nil]
      def self.nats_wrapper
        connector = PluginManager['connector_plugin']
        connector.respond_to?(:connection) ? connector.connection : nil
      end

      # The bytes the connector would publish for one direct request from
      # this RPC client to the identity, built as the client and the
      # connector build a request and never sent.
      #
      # @param client [MCollective::RPC::Client] The client the request would go through
      # @return [Integer]
      def self.request_bytes(client, action, args, identity)
        options = client.options
        framing = { agent: client.agent, type: :request, collective: options[:collective], filter: options[:filter], options: options }
        message = Message.new(client.new_request(action, args), nil, framing)
        message.discovered_hosts = [identity]
        message.type = :direct_request
        message.encode!
        message.base64_encode!
        target = PluginManager['connector_plugin'].target_for(message, identity)
        { 'protocol' => 'choria:transport:1', 'data' => message.payload, 'headers' => target[:headers] }.to_json.bytesize
      end

      # Builds one RPC client per call from an options hash, the way an mco
      # application does, and serializes the calls, because the publish
      # guard keeps its limit in module state while a call runs. A caller
      # with its own client handling, such as OpenBolt, gives the Client its
      # own object with these two methods instead.
      class Connection
        # @param options [Hash] The client options, Util.default_options by default
        def initialize(options = Util.default_options)
          @options = options
          @mutex = Mutex.new
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
            options = @options.merge(timeout: timeout, verbose: false)
            if publish_timeout
              options[:publish_timeout] = publish_timeout
              options[:threaded] = false
            end
            client = RPC::Client.new(agent, options: options)
            client.progress = false
            client.discover(nodes: identities)
            yield(client)
          end
        end

        def nats_wrapper
          FileTransfer.nats_wrapper
        end
      end
    end
  end
end
