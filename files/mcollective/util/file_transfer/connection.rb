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
        # What the security and connector plugins put around every request
        # of this process. The signature and certificate are the strings the
        # signer attached to one request, and every later request repeats
        # their lengths, since the same identity signs them all.
        Signing = Data.define(:identity, :callerid, :collective, :ttl, :signature, :pubcert, :federated)

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

        # The values the request layers carry, read once. The signature and
        # the certificate come from asking the security plugin to sign one
        # request shaped like a put with no content, which never leaves the
        # process. With a remote signer they come back from that service
        # and exist nowhere on this host until then, so signing one request
        # is the one way to have them in every signer mode. The identity,
        # collective, and ttl are what the client puts in the envelope, and
        # the federation flag is the connector's own.
        #
        # @param agent [String] The agent the signed request names
        # @return [Signing]
        def signing(agent)
          @signing ||= begin
            security = PluginManager['security_plugin']
            identity = Config.instance.identity
            collective = @options[:collective] || Config.instance.main_collective
            ttl = @options[:ttl] || Config.instance.ttl
            filter = Util.empty_filter
            filter['agent'] << agent
            body = { agent: agent, action: 'put', caller: security.callerid, data: {} }
            secure = JSON.parse(security.encoderequest(identity, body, SSL.uuid.delete('-'), filter, agent, collective, ttl))
            Signing.new(identity: identity, callerid: security.callerid, collective: collective, ttl: ttl,
              signature: secure.fetch('signature'), pubcert: secure.fetch('pubcert'), federated: Util::Choria.new(false).federated?)
          end
        end
      end
    end
  end
end
