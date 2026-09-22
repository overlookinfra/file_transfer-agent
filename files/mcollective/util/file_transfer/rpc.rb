# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # The RPC calls of a transfer, the timeouts they run under, and the
      # sizing of its requests through the connection they go out on. Every
      # call answers a response hash with the replies by identity under
      # :responded, the failures by identity under :errors as Outcomes, and
      # :rpc_failed when the whole call raised.
      class Rpc
        LIVENESS_TIMEOUT = 5
        MIN_CHUNK_TIMEOUT = 5
        CHUNK_TIMEOUT_FACTOR = 3
        BYTES_PER_EXTRA_SECOND = 100_000_000
        PROBE_SESSION = '00000000-0000-4000-8000-000000000000'

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
          errors = Outcome.failures(identities, :rpc_failed) { |identity| "#{context} failed on #{identity}: #{e.message}" }
          empty_response.merge(errors: errors, rpc_failed: true)
        end

        # Whether a call that brought no reply failed for a reason the guard
        # cannot see. Silent nodes are pinged first, so a dead node is a
        # plain no_response failure rather than a reason to shrink.
        def blind_failure(response, identities, reconnects_before)
          return nil if identities.empty?
          return nil unless response[:responded].empty?

          lost = response[:rpc_failed] || response[:errors].values.all? { |outcome| outcome.kind == :no_response }
          return nil unless lost
          return :reconnect if wrapper_stat(:reconnects) > reconnects_before
          return nil if response[:rpc_failed]

          alive = request('rpcutil', identities, 'rpcutil.ping', timeout: LIVENESS_TIMEOUT, publish_timeout: nil, &:ping)
          alive[:responded].empty? ? nil : :silent
        end

        # One counter of the NATS wrapper, in_bytes or reconnects, or 0 when
        # the connector keeps none.
        def wrapper_stat(key)
          wrapper = @connection.nats_wrapper
          stats = wrapper.respond_to?(:stats) ? wrapper.stats : nil
          stats.is_a?(Hash) ? stats.fetch(key, 0).to_i : 0
        rescue StandardError
          0
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

        # Sizes chunks from the broker's advertised limit and two
        # serializations of a put through the real client, captured at the
        # NATS wrapper without sending. The probes carry an empty chunk and
        # an incompressible one, encoded exactly as a chunk is, so the
        # expansion they measure includes what deflate adds.
        def chunk_sizing(identities, chunk_size)
          wrapper = @connection.nats_wrapper
          sizing = Sizing.new(max_payload: advertised_max_payload(wrapper), chunk_size: chunk_size)
          empty = full = nil
          if wrapper.class.method_defined?(:publish)
            PublishHook.install(wrapper.class)
            empty = probe_size(identities, FileTransfer.encode_chunk(''))
            full = probe_size(identities, FileTransfer.encode_chunk(SecureRandom.random_bytes(Sizing::PROBE_BYTES)))
          end
          if empty && full && full > empty
            sizing.calibrate(envelope: empty, expansion: (full - empty).to_f / Sizing::PROBE_BYTES)
          else
            @logger.warn_once('file_transfer_sizing_fallback',
              'The file transfer client could not measure the size of its own requests, so chunks are sized from a ' \
              'conservative estimate. Lower the chunk size if transfers report oversized messages.')
            sizing.fallback
          end
          @logger.debug("File transfer with #{FileTransfer.count(identities)} uses #{sizing.summary}")
          sizing
        end

        private

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

        def advertised_max_payload(wrapper)
          client = wrapper&.instance_variable_get(:@client)
          limit = client.server_info[:max_payload] if client.respond_to?(:server_info) && client.server_info.is_a?(Hash)
          return limit if limit.is_a?(Integer) && limit.positive?

          @logger.warn_once('file_transfer_max_payload_unknown',
            "The file transfer client could not read the broker's message size limit and assumes #{Sizing::DEFAULT_MAX_PAYLOAD} bytes")
          Sizing::DEFAULT_MAX_PAYLOAD
        end

        # One put through the real client with the probe set, so the wire
        # size of this transfer's requests is seen and nothing is sent.
        # Answers nil when the probe could not run.
        def probe_size(identities, data)
          @connection.with_client(AGENT, identities, timeout: @rpc_timeout, publish_timeout: @rpc_timeout) do |client|
            PublishHook.probed_size = nil
            PublishHook.probing = true
            begin
              client.put(session: PROBE_SESSION, name: 'probe', offset: 0, data: data)
            rescue ProbeCaptured
              nil
            ensure
              PublishHook.probing = false
            end
          end
          PublishHook.probed_size
        rescue StandardError => e
          @logger.debug("The chunk sizing probe failed: #{e.class}: #{e.message}")
          nil
        end

        def empty_response
          { responded: {}, errors: {}, rpc_failed: false, statuscodes: {}, statusmsgs: {} }
        end
      end
    end
  end
end
