# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # Raised by the publish guard before a message larger than the broker's
      # limit reaches the socket. The broker would otherwise close the
      # connection and the caller would only see a timeout.
      class PayloadTooLarge < StandardError
        attr_reader :size, :limit

        def initialize(size, limit)
          @size = size
          @limit = limit
          super("a #{size} byte message exceeds the broker's #{limit} byte payload limit")
        end

        def overshoot
          size - limit
        end
      end

      # Raised by the sizing probe to abandon a request once its wire size
      # has been seen. A plain StandardError, because the client library
      # swallows Timeout::Error and Interrupt around publishing.
      class ProbeCaptured < StandardError; end

      # Prepended onto the NATS wrapper class so that every message published
      # while a transfer runs passes through here. While probing, the size
      # is recorded and the send abandoned. With a limit set, a message over
      # it is refused. Both are set only inside the connection's with_client,
      # which serializes calls, so no other request publishes meanwhile.
      module PublishHook
        class << self
          attr_accessor :limit, :probing, :probed_size

          def install(wrapper_class)
            wrapper_class.prepend(self) unless wrapper_class.ancestors.include?(self)
          end
        end

        def publish(destination, payload, reply = nil)
          if PublishHook.probing
            PublishHook.probed_size = payload.bytesize
            raise ProbeCaptured
          end

          limit = PublishHook.limit
          raise PayloadTooLarge.new(payload.bytesize, limit) if limit && payload.bytesize > limit

          super
        end
      end

      # The chunk arithmetic for one transfer. The client feeds it the
      # broker's advertised limit, the two probe sizes, guard overshoots,
      # blind failures, and reply measurements. It answers how many bytes of
      # file content the next request or reply may carry.
      class Sizing
        DEFAULT_MAX_PAYLOAD = 1_048_576
        RESERVE_FRACTION = 0.05
        PROBE_BYTES = 32_768
        # Without a probe, wire bytes per content byte are unknown. Base64
        # twice over is at least 1.78, so this leaves room for the envelope.
        FALLBACK_DIVISOR = 2.5
        MINIMUM_CHUNK = 16_384
        GUARD_CUSHION = 0.01
        BLIND_REDUCTION = 0.2
        FIRST_REPLY_DIVISOR = 4
        UNMEASURED_REPLY_DIVISOR = 3
        MINIMUM_REPLY = MINIMUM_CHUNK / FIRST_REPLY_DIVISOR
        # A round measures the reply expansion only when it carried at least
        # this share of the content it asked for. A short tail pays the whole
        # reply envelope for a few bytes and would set the expansion far too
        # high for every round after it.
        MEASURABLE_ROUND_FRACTION = 0.5

        attr_reader :max_payload, :chunk_bytes, :reply_expansion, :reply_ceiling, :last_reply_bytes

        # @param max_payload [Integer] The broker's advertised limit in bytes
        # @param chunk_size [Integer] The most content a caller wants in one request
        def initialize(max_payload:, chunk_size:)
          @max_payload = max_payload
          @chunk_size = chunk_size
          @chunk_bytes = nil
          @reply_expansion = nil
          @reply_ceiling = nil
          @last_reply_bytes = nil
        end

        def reserve
          (@max_payload * RESERVE_FRACTION).ceil
        end

        # @param envelope [Integer] Wire size of a put request with empty data
        # @param expansion [Float] Wire bytes added per byte of file content
        def calibrate(envelope:, expansion:)
          @envelope = envelope
          @expansion = expansion
          @chunk_bytes = [((@max_payload - reserve - envelope) / expansion).floor, @chunk_size].min
          self
        end

        def fallback
          @envelope = nil
          @expansion = nil
          @chunk_bytes = [((@max_payload - reserve) / FALLBACK_DIVISOR).floor, @chunk_size].min
          self
        end

        def calibrated?
          !@expansion.nil?
        end

        def usable?
          !@chunk_bytes.nil? && @chunk_bytes >= MINIMUM_CHUNK
        end

        # After the guard refused a message. The overshoot is in wire bytes,
        # so it is divided by the expansion to reach content bytes, with the
        # expansion taken as 1.0 when it is unknown, which shrinks more.
        def shrink_by_overshoot(overshoot)
          content = (overshoot / (@expansion || 1.0)).ceil
          @chunk_bytes = [@chunk_bytes - content - (@chunk_bytes * GUARD_CUSHION).ceil, 0].max
          self
        end

        # After a whole group went silent or the broker dropped the
        # connection. A download's request is bounded by the reply budget
        # rather than the chunk, so the last reply size handed out shrinks
        # by the same fraction and the retry asks for less.
        def shrink_blind
          @chunk_bytes = (@chunk_bytes * (1 - BLIND_REDUCTION)).floor
          @reply_ceiling = (@last_reply_bytes * (1 - BLIND_REDUCTION)).floor if @last_reply_bytes
          self
        end

        # Replies are produced by the node's server with its own protocol
        # version, so their expansion is measured rather than probed. The
        # largest ratio seen wins, since a small reply carries the same fixed
        # envelope as a large one.
        #
        # @param wire_bytes [Integer] Bytes received during a call
        # @param content_bytes [Integer] File content bytes those replies carried
        # @param requested_bytes [Integer] Content bytes the call asked for in total
        def record_replies(wire_bytes, content_bytes, requested_bytes)
          return self unless wire_bytes.positive? && content_bytes.positive?
          return self if content_bytes < requested_bytes * MEASURABLE_ROUND_FRACTION

          ratio = wire_bytes.to_f / content_bytes
          @reply_expansion = [@reply_expansion || 0.0, ratio].max
          self
        end

        # Whether a download can still ask for anything. The reply budget has
        # its own floor, since a get request is tiny and the chunk minimum
        # says nothing about what a reply may carry.
        def reply_usable?
          @reply_ceiling.nil? || @reply_ceiling >= MINIMUM_REPLY
        end

        # How many bytes of content to ask for in one get, never below the
        # reply minimum so that every round makes progress.
        #
        # @param measurable [Boolean] Whether reply sizes can be measured at all
        def reply_bytes(measurable:)
          budget = if !measurable
                     @chunk_bytes / UNMEASURED_REPLY_DIVISOR
                   elsif @reply_expansion.nil?
                     @chunk_bytes / FIRST_REPLY_DIVISOR
                   else
                     [@chunk_bytes, ((@max_payload - reserve) / @reply_expansion).floor].min
                   end
          @last_reply_bytes = [[budget, @reply_ceiling].compact.min, MINIMUM_REPLY].max
        end

        def summary
          if calibrated?
            "chunks of #{@chunk_bytes} bytes (broker limit #{@max_payload}, envelope #{@envelope}, " \
              "#{format('%.2f', @expansion)} wire bytes per content byte, chunk size #{@chunk_size})"
          else
            "chunks of #{@chunk_bytes} bytes (broker limit #{@max_payload}, sizing not probed, chunk size #{@chunk_size})"
          end
        end
      end
    end
  end
end
