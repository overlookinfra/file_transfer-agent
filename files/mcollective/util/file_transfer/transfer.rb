# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # The identities still taking part in one transfer, the failures that
      # removed the others, the chunk sizing, and the timing the chunk
      # timeout is derived from.
      class Transfer
        # nats-pure drops replies once a subscription holds this many bytes
        # unread, so one download round stays well under it.
        REPLY_PENDING_LIMIT = 64 * 1024 * 1024
        REPLY_PENDING_FRACTION = 0.75
        # The client keeps a copy of a chunk request for every node of an
        # upload batch in memory until the flusher has written it, so a
        # batch is bounded to this many bytes at the broker's limit unless
        # the caller chose its own size.
        UPLOAD_BATCH_BYTES = 256 * 1024 * 1024

        attr_reader :identities, :active, :failures, :sizing, :slowest_chunk

        # A transfer for the identities with its chunks sized to the broker's
        # limit, and every identity failed when that limit leaves no room
        # for a chunk.
        def self.start(identities, rpc:, logger:, chunk_size:)
          sizing = Sizing.new(max_payload: rpc.max_payload, chunk_size: chunk_size)
          logger.debug("File transfer with #{FileTransfer.count(identities)} uses #{sizing.summary}")
          transfer = new(identities, sizing, logger)
          return transfer if sizing.usable?

          transfer.fail(Outcome.failures(identities, :payload_too_large) do
            "The broker's payload limit of #{sizing.max_payload} bytes leaves less than #{Sizing::MINIMUM_CHUNK} bytes " \
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
        def download_group_size(preferred)
          bounded = [(REPLY_PENDING_LIMIT * REPLY_PENDING_FRACTION / @sizing.max_payload).floor, 1].max
          return preferred if preferred <= bounded

          @logger.warn_once('file_transfer_download_group_bounded',
            "The download group size of #{preferred} is reduced to #{bounded} so one round of replies stays " \
            "under the client's #{REPLY_PENDING_LIMIT} byte subscription buffer")
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
