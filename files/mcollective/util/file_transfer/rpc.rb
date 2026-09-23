# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # The RPC calls of a transfer, the timeouts they run under, and the
      # broker's limit on what they may carry. Every call answers a response
      # hash with the replies by identity under :responded, the failures by
      # identity under :errors as Outcomes, and :rpc_failed when the whole
      # call raised.
      class Rpc
        MIN_CHUNK_TIMEOUT = 5
        CHUNK_TIMEOUT_FACTOR = 3
        BYTES_PER_EXTRA_SECOND = 100_000_000

        attr_reader :rpc_timeout

        def initialize(connection, logger, rpc_timeout)
          @connection = connection
          @logger = logger
          @rpc_timeout = rpc_timeout
        end

        # One call to the file_transfer agent, with the rules that status
        # code 1 is a failure for every one of its actions and that a reply
        # without a data hash is one too. The publish timeout is raised to
        # the rpc timeout so that one chunk reaches every node of a large
        # group.
        def agent_call(identities, context, timeout: nil, &)
          return empty_response if identities.empty?

          response = request(AGENT, identities, context, timeout: timeout || @rpc_timeout, publish_timeout: @rpc_timeout, &)
          response[:statuscodes].each do |identity, code|
            next unless code == 1

            response[:responded].delete(identity)
            response[:errors][identity] = Outcome.failure(identity, :transfer_failed,
              "#{context} on #{identity} failed: #{response[:statusmsgs][identity]}")
          end
          response[:responded].reject { |_identity, data| data.is_a?(Hash) }.each_key do |identity|
            response[:responded].delete(identity)
            response[:errors][identity] = Outcome.failure(identity, :transfer_failed, "#{context} on #{identity} answered without usable data")
          end
          response
        end

        # One call to any agent, yielding the RPC client to invoke the action
        # on. Status codes above 1 are RPC errors, a missing reply is a
        # no_response failure, and an exception fails every identity.
        def request(agent, identities, context, timeout:, publish_timeout:, &)
          results = @connection.with_client(agent, identities, timeout: timeout, publish_timeout: publish_timeout, &)
          by_sender = index_by_sender(results.is_a?(Array) ? results : [], identities, context)
          response = empty_response
          identities.each do |identity|
            result = by_sender[identity]
            if result.nil?
              response[:errors][identity] = Outcome.failure(identity, :no_response, "No response from #{identity} for #{context}")
              next
            end

            response[:statuscodes][identity] = result[:statuscode]
            response[:statusmsgs][identity] = result[:statusmsg]
            if result[:statuscode] > 1
              response[:errors][identity] = Outcome.failure(identity, :rpc_error,
                "#{context} on #{identity} returned RPC error: #{result[:statusmsg]} (code #{result[:statuscode]})")
            else
              response[:responded][identity] = result[:data]
            end
          end
          response
        rescue StandardError => e
          @logger.warn("#{context} RPC call failed: #{e.class}: #{e.message}")
          @logger.debug(e.backtrace.join("\n")) if e.backtrace
          errors = Outcome.failures(identities, :rpc_failed) { |identity| "#{context} failed on #{identity}: #{e.class}: #{e.message}" }
          empty_response.merge(errors: errors, rpc_failed: true)
        end

        # The broker's advertised payload limit, or the default with a
        # warning naming why it could not be read.
        def max_payload
          limit = @connection.nats_wrapper.instance_variable_get(:@client).server_info[:max_payload]
          return limit if limit.is_a?(Integer) && limit.positive?

          unknown_max_payload("the server info says #{limit.inspect}")
        rescue StandardError => e
          unknown_max_payload("#{e.class}: #{e.message}")
        end

        # Runs the block with the publish guard set to the limit, so a
        # message over it raises PayloadTooLarge before it leaves the client
        # instead of making the broker close the connection. Without a
        # wrapper to hook the block still runs, after a warning that the
        # guard is off.
        def guarding(limit)
          install_guard
          PublishHook.limit = limit
          yield
        ensure
          PublishHook.limit = nil
        end

        # Three times the slowest chunk so far, at least MIN_CHUNK_TIMEOUT,
        # and never above the rpc timeout. An rpc timeout below the floor is
        # the whole budget, so the floor cannot apply.
        def chunk_timeout(transfer)
          return @rpc_timeout if transfer.slowest_chunk.nil? || @rpc_timeout <= MIN_CHUNK_TIMEOUT

          (transfer.slowest_chunk * CHUNK_TIMEOUT_FACTOR).ceil.clamp(MIN_CHUNK_TIMEOUT, @rpc_timeout)
        end

        # The rpc timeout plus a second per 100 MB of file, capped at the DDL
        # timeout unless the rpc timeout is itself above that.
        def final_timeout(size)
          (@rpc_timeout + (size / BYTES_PER_EXTRA_SECOND)).clamp(@rpc_timeout, [DDL_TIMEOUT, @rpc_timeout].max)
        end

        private

        def unknown_max_payload(reason)
          @logger.warn_once('file_transfer_max_payload_unknown',
            "The file transfer client could not read the broker's message size limit (#{reason}) and assumes " \
            "#{Sizing::DEFAULT_MAX_PAYLOAD} bytes")
          Sizing::DEFAULT_MAX_PAYLOAD
        end

        def install_guard
          wrapper = @connection.nats_wrapper
          return PublishHook.install(wrapper.class) if wrapper.class.method_defined?(:publish)

          guard_unavailable("#{wrapper.inspect} has no publish method")
        rescue StandardError => e
          guard_unavailable("#{e.class}: #{e.message}")
        end

        def guard_unavailable(reason)
          @logger.warn_once('file_transfer_guard_unavailable',
            "The file transfer client cannot check its requests against the broker's message size limit (#{reason}), " \
            'so a request over it would drop the connection instead of failing')
        end

        # The first reply per identity, from the identities addressed only.
        def index_by_sender(results, identities, context)
          expected = identities.to_set
          by_sender = {}
          results.each do |result|
            sender = result[:sender]
            if sender.nil?
              @logger.warn("Discarding #{context} response with nil sender")
            elsif !expected.include?(sender)
              @logger.warn("Discarding #{context} response from unexpected sender #{sender.inspect}")
            elsif by_sender.key?(sender)
              @logger.warn("Ignoring duplicate #{context} response from #{sender}")
            else
              by_sender[sender] = result
            end
          end
          by_sender
        end

        def empty_response
          { responded: {}, errors: {}, rpc_failed: false, statuscodes: {}, statusmsgs: {} }
        end
      end
    end
  end
end
