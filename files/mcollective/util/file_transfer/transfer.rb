# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # The identities still taking part in one transfer, the failures that
      # removed the others, the chunk sizing, and the timing the chunk
      # timeout is derived from.
      class Transfer
        # Every reply of a download round lands on the client's one broker
        # connection. nats-server closes a connection whose unread backlog
        # passes this many bytes, after stalling the senders above the
        # fraction below, and the Choria broker keeps both, so one round of
        # replies stays under the stall threshold.
        BROKER_PENDING_LIMIT = 64 * 1024 * 1024
        BROKER_STALL_FRACTION = 0.75
        # The client keeps a copy of a chunk request for every node of an
        # upload batch in memory until the flusher has written it, so a
        # batch is bounded to this many bytes at the broker's limit unless
        # the caller chose its own size.
        UPLOAD_BATCH_BYTES = 256 * 1024 * 1024

        attr_reader :identities, :active, :failures, :sizing, :slowest_chunk

        # A transfer for the identities under the broker's limit.
        def self.start(identities, rpc:, logger:, chunk_size:)
          sizing = Sizing.new(max_payload: rpc.max_payload, chunk_size: chunk_size, rpc: rpc, identity: identities.first)
          logger.debug("File transfer with #{FileTransfer.count(identities)} has #{sizing.summary}")
          new(identities, sizing, logger)
        end

        def initialize(identities, sizing, logger)
          @identities = identities.dup
          @active = identities.dup
          @failures = {}
          @sizing = sizing
          @logger = logger
          @slowest_chunk = nil
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

        # How many nodes one download round asks at once, as many as keep
        # one round of replies of the given wire size under the broker's
        # stall threshold, or the caller's smaller choice.
        def download_batch_size(preferred, reply_wire)
          bounded = [(BROKER_PENDING_LIMIT * BROKER_STALL_FRACTION / reply_wire).floor, 1].max
          return bounded if preferred.nil?
          return preferred if preferred <= bounded

          @logger.warn_once('file_transfer_download_batch_bounded',
            "The download batch size of #{preferred} is reduced to #{bounded} so one round of replies stays " \
            "under three quarters of the #{BROKER_PENDING_LIMIT} bytes the broker holds for a connection before closing it")
          bounded
        end

        # How many nodes one chunk request is published to at once, the
        # caller's choice or as many as keep a batch under UPLOAD_BATCH_BYTES.
        def upload_batch_size(preferred)
          preferred || [UPLOAD_BATCH_BYTES / @sizing.max_payload, 1].max
        end
      end
    end
  end
end
