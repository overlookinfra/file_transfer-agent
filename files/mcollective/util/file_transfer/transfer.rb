# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # The identities still taking part in one transfer, the failures that
      # removed the others, the chunk sizing and the reductions it went
      # through, and the timing the chunk timeout is derived from.
      class Transfer
        # nats-pure drops replies once a subscription holds this many bytes
        # unread, so one download round stays well under it.
        REPLY_PENDING_LIMIT = 64 * 1024 * 1024
        REPLY_PENDING_FRACTION = 0.75

        attr_reader :identities, :active, :failures, :sizing, :slowest_chunk, :reductions, :last_reduction

        # A transfer for the identities with its chunks sized through the
        # rpc, and every identity failed when the broker's limit leaves no
        # room for a chunk.
        def self.start(identities, rpc:, logger:, chunk_size:)
          transfer = new(identities, rpc.chunk_sizing(identities, chunk_size), logger)
          return transfer if transfer.sizing.usable?

          transfer.fail(Outcome.failures(identities, :payload_too_large) do
            "The broker's payload limit of #{transfer.sizing.max_payload} bytes leaves less than #{Sizing::MINIMUM_CHUNK} bytes " \
              'of file content per request, so files cannot be transferred'
          end)
          transfer
        end

        def initialize(identities, sizing, logger)
          @identities = identities.dup
          @active = identities.dup
          @failures = {}
          @sizing = sizing
          @logger = logger
          @slowest_chunk = nil
          @reductions = Hash.new(0)
          @last_reduction = nil
        end

        # @param outcomes [Hash{String => Outcome}] The failure of each identity to drop
        def fail(outcomes)
          dropped = @active & outcomes.keys
          dropped.each { |identity| @failures[identity] = outcomes[identity] }
          @active -= dropped
        end

        def active?
          !@active.empty?
        end

        def record_chunk(seconds)
          @slowest_chunk = [@slowest_chunk || 0, seconds].max
        end

        # One Outcome per identity, in the order the transfer was given
        # them. The block answers the delivered path of an identity that
        # was not failed, and nil for one nothing was delivered to.
        def outcomes
          @identities.to_h do |identity|
            outcome = @failures[identity]
            if outcome.nil?
              path = yield(identity)
              outcome = path ? Outcome.success(identity, path) : Outcome.failure(identity, :transfer_failed, "Nothing was delivered for #{identity}")
            end
            [identity, outcome]
          end
        end

        # The download group size, lowered so that one round of replies at
        # the broker's limit fits the client's subscription buffer.
        def group_size(preferred)
          bounded = [(REPLY_PENDING_LIMIT * REPLY_PENDING_FRACTION / @sizing.max_payload).floor, 1].max
          return preferred if preferred <= bounded

          @logger.warn_once('file_transfer_download_group_bounded',
            "The download group size of #{preferred} is reduced to #{bounded} so one round of replies stays " \
            "under the client's #{REPLY_PENDING_LIMIT} byte subscription buffer")
          bounded
        end

        # Shrinks the chunk after the publish guard refused a request.
        def shrink_after_guard(refused, identities)
          before = @sizing.chunk_bytes
          @sizing.shrink_by_overshoot(refused.overshoot)
          note_reduction(:guard, "a request of #{refused.size} bytes exceeded the broker's limit by #{refused.overshoot} bytes",
            before, @sizing.chunk_bytes, identities, @sizing.usable?)
        end

        # Shrinks after a whole group went silent or the broker dropped the
        # connection. An upload shrinks the chunk it sends, a download the
        # reply budget it asks for, so the sizes reported and the test for
        # whether the transfer can go on come from the side that failed.
        def shrink_blind(cause, identities, reply: false)
          before = reply ? @sizing.last_reply_bytes : @sizing.chunk_bytes
          @sizing.shrink_blind
          after = reply ? @sizing.reply_ceiling : @sizing.chunk_bytes
          description = cause == :reconnect ? 'the broker closed the connection during the request' : 'every node stayed silent but answers a ping'
          note_reduction(cause, description, before, after, identities, reply ? @sizing.reply_usable? : @sizing.usable?)
        end

        # Failures for the identities still waiting for data once the sizing
        # can shrink no further.
        def payload_failures(identities, what, minimum)
          cause = @last_reduction || 'the broker refused a message it did not explain'
          Outcome.failures(identities, :payload_too_large) { |identity| "#{what} could not be transferred with #{identity} because #{cause}, and #{minimum}" }
        end

        def report_reductions
          return if @reductions.empty?

          counts = @reductions.map { |cause, number| "#{cause} #{number}" }.join(', ')
          @logger.warn("File transfer chunk reductions this run: #{counts}")
        end

        private

        # A reduction is always worth the operator's attention, since it
        # means a deployment setting is out of step with the broker. The
        # caller fails the identities still waiting for data once the sizing
        # is no longer usable.
        def note_reduction(cause, description, before, after, identities, usable)
          @reductions[cause] += 1
          @last_reduction = description
          limit = @sizing.max_payload
          names = identities.join(', ')
          if usable
            @logger.warn_once("file_transfer_reduction_#{cause}",
              "File transfer chunks shrink from #{before} to #{after} bytes per request because #{description} " \
              "(broker limit #{limit} bytes, nodes #{names}). Lower the chunk size below #{after} to avoid the retries, " \
              "or raise the broker's payload limit.")
          else
            @logger.warn("File transfer chunks cannot shrink below #{after} bytes per request after #{description} " \
                         "(broker limit #{limit} bytes, nodes #{names})")
          end
        end
      end
    end
  end
end
