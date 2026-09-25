# frozen_string_literal: true

require_relative 'outcome'
require_relative 'rpc'

module MCollective
  module Util
    module FileTransfer
      # How much one message may carry under the broker's payload limit, and
      # how many nodes one call goes to at once. The fixed parts of a
      # request are measured on one the connector would publish, the
      # content is arithmetic on the two base64 encodings it passes
      # through, and the result is confirmed on a request of that size.
      class Sizing
        DEFAULT_MAX_PAYLOAD = 1_048_576
        # Kept back from the limit for what the client cannot see, such as
        # the headers a federation broker rewrites in flight.
        RESERVE_FRACTION = 0.05
        MINIMUM_CHUNK = 16_384
        # Beyond any file's offset, so a measured request is at least as
        # large as any chunk of the content takes.
        MEASURED_OFFSET = 10**15
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

        # @param connection [Connection] Reads the broker's limit and builds the requests that are measured
        # @param logger [#warn_once] Told once when the limit cannot be read, a request weighs more
        #   than computed, or a download batch is reduced
        # @param chunk_size [Integer, nil] The most content a caller wants in one request, or nil
        #   for whatever the limit allows
        # @param upload_batch_size [Integer, nil] The caller's choice of nodes per chunk request, or nil
        # @param download_batch_size [Integer, nil] The caller's choice of nodes per download round, or nil
        def initialize(connection, logger, chunk_size:, upload_batch_size:, download_batch_size:)
          @connection = connection
          @logger = logger
          @chunk_size = chunk_size
          @upload_batch_size = upload_batch_size
          @download_batch_size = download_batch_size
        end

        # What the connector's outer base64 makes of a signed request of
        # this many bytes: four characters per three bytes, and the newline
        # Base64.encode64 puts after every 60 characters, which the
        # transport JSON escapes to two.
        def self.encoded_bytes(signed_bytes)
          characters = 4 * ((signed_bytes + 2) / 3)
          characters + (2 * ((characters + 59) / 60))
        end

        # The broker's advertised payload limit, read once, or the default
        # with a warning naming why it could not be read.
        def max_payload
          @max_payload ||= read_max_payload
        end

        # The bytes of the limit a request may use.
        def budget
          @budget ||= (max_payload * (1 - RESERVE_FRACTION)).floor
        end

        # The most content one put of this name to this destination may
        # carry, or 0 when even the minimum does not fit. A request with no
        # content gives the fixed parts, the signed request and the
        # transport framing around its encoding. The content is then what
        # the budget leaves room for: the largest signed request whose
        # encoding fits beside the framing, less the empty one, in base64
        # groups of four characters per three bytes. A get reply carrying
        # as much weighs less, since the node signs nothing and sends no
        # certificate, so downloads ask for the same.
        #
        # @param identity [String] A node the measured requests are addressed to
        def content_bytes(name, destination, identity)
          empty = measure(0, name, destination, identity)
          room = budget - (empty.wire_bytes - Sizing.encoded_bytes(empty.signed_bytes))
          return 0 if room < MINIMUM_CHUNK

          # encoded_bytes grows by 62 for every 45 signed bytes, so this is
          # close, and the two loops settle it on the exact largest.
          signed = room * 45 / 62
          signed -= 1 while Sizing.encoded_bytes(signed) > room
          signed += 1 while Sizing.encoded_bytes(signed + 1) <= room
          content = 3 * ((signed - empty.signed_bytes) / 4)
          content = [content, @chunk_size].min if @chunk_size
          content < MINIMUM_CHUNK ? 0 : confirm(content, name, destination, identity)
        end

        # The bytes the connector would publish for a final put of this
        # much content, the largest shape a chunk request takes.
        def wire_bytes(content, name, destination, identity)
          measure(content, name, destination, identity).wire_bytes
        end

        # How many nodes one chunk request is published to at once, the
        # caller's choice or as many as keep a batch under UPLOAD_BATCH_BYTES.
        def upload_batch_size
          @upload_batch_size || [UPLOAD_BATCH_BYTES / max_payload, 1].max
        end

        # How many nodes one download round asks at once, as many as keep
        # one round of replies of the given wire size under the broker's
        # stall threshold, or the caller's smaller choice.
        def download_batch_size(reply_wire)
          bounded = [(BROKER_PENDING_LIMIT * BROKER_STALL_FRACTION / reply_wire).floor, 1].max
          return bounded if @download_batch_size.nil?
          return @download_batch_size if @download_batch_size <= bounded

          @logger.warn_once('file_transfer_download_batch_bounded',
            "The download batch size of #{@download_batch_size} is reduced to #{bounded} so one round of replies stays " \
            "under three quarters of the #{BROKER_PENDING_LIMIT} bytes the broker holds for a connection before closing it")
          bounded
        end

        # A payload_too_large failure per identity for a file whose
        # content_bytes came out as 0, for an upload or a download.
        #
        # @return [Hash{String => Outcome}]
        def too_small_failures(identities, name, direction)
          per, verb = direction == :upload ? ['request', 'sent to'] : ['reply', 'fetched from']
          Outcome.failures(identities, :payload_too_large) do |identity|
            "The broker's payload limit of #{max_payload} bytes leaves less than #{MINIMUM_CHUNK} bytes of file content " \
              "per #{per}, so #{name} cannot be #{verb} #{identity}"
          end
        end

        def summary
          cap = @chunk_size ? "chunk size #{@chunk_size}" : 'no chunk size'
          "#{budget} usable bytes of the #{max_payload} byte broker limit (#{cap})"
        end

        private

        def read_max_payload
          limit = @connection.max_payload
          return limit if limit.is_a?(Integer) && limit.positive?

          unknown_max_payload("the server info says #{limit.inspect}")
        rescue StandardError => e
          unknown_max_payload("#{e.class}: #{e.message}")
        end

        def unknown_max_payload(reason)
          @logger.warn_once('file_transfer_max_payload_unknown',
            "The file transfer client could not read the broker's message size limit (#{reason}) and assumes " \
            "#{DEFAULT_MAX_PAYLOAD} bytes")
          DEFAULT_MAX_PAYLOAD
        end

        def measure(content, name, destination, identity)
          args = { session: 's' * 36, name: name, offset: MEASURED_OFFSET, data: ['x' * content].pack('m0'),
                   final: true, sha256: 'f' * 64, destination: destination, mode: '0777' }
          @connection.request_bytes(Rpc::AGENT, 'put', args, identity)
        end

        # Builds the request the content would go out in and answers the
        # content when it fits the budget. When it does not, the connector
        # frames requests differently than the arithmetic assumes, which is
        # said once, and the excess comes off the content, since a content
        # byte weighs more than one wire byte.
        def confirm(content, name, destination, identity)
          wire = measure(content, name, destination, identity).wire_bytes
          return content if wire <= budget

          @logger.warn_once('file_transfer_sizing_mismatch',
            "A request of #{content} content bytes weighed #{wire} bytes against the #{budget} computed for it, so the " \
            'connector frames requests differently than the sizing assumes and chunks are reduced by the difference')
          reduced = content - (wire - budget)
          reduced < MINIMUM_CHUNK ? 0 : reduced
        end
      end
    end
  end
end
