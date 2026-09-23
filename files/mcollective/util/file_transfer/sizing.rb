# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # Raised by the publish guard before a message larger than the broker's
      # limit reaches the socket. The broker would otherwise close the
      # connection and the caller would only see a timeout.
      class PayloadTooLarge < StandardError
        def initialize(size, limit)
          super("a #{size} byte message exceeds the broker's #{limit} byte payload limit")
        end
      end

      # Prepended onto the NATS wrapper class so that every message published
      # while a chunk is sent passes through here, a message over the limit
      # is refused, and the largest one is remembered for the debug line
      # that gives the real wire expansion of a chunk. The limit is set
      # only inside the connection's with_client, which serializes calls,
      # so no other request publishes meanwhile.
      module PublishHook
        class << self
          attr_accessor :limit, :largest

          def install(wrapper_class)
            wrapper_class.prepend(self) unless wrapper_class.ancestors.include?(self)
          end
        end

        def publish(destination, payload, reply = nil)
          limit = PublishHook.limit
          if limit
            raise PayloadTooLarge.new(payload.bytesize, limit) if payload.bytesize > limit

            PublishHook.largest = [PublishHook.largest, payload.bytesize].max
          end

          super
        end
      end

      # How many bytes of file content one request and one reply may carry
      # under the broker's payload limit.
      class Sizing
        DEFAULT_MAX_PAYLOAD = 1_048_576
        RESERVE_FRACTION = 0.05
        # Wire bytes per content byte. Base64 twice over is at least 1.78,
        # so this leaves room for the request envelope.
        EXPANSION = 2.5
        MINIMUM_CHUNK = 16_384
        # A reply is built by the node's server, whose v1 transport base64
        # encodes the secure reply as the client encodes a request, so it
        # carries the same two passes. A third of the request budget keeps
        # replies well inside the limit and download batches large.
        REPLY_DIVISOR = 3

        attr_reader :max_payload, :chunk_bytes, :reply_bytes

        # @param max_payload [Integer] The broker's advertised limit in bytes
        # @param chunk_size [Integer, nil] The most content a caller wants in one request, or nil
        #   for whatever the limit allows
        def initialize(max_payload:, chunk_size:)
          @max_payload = max_payload
          @chunk_size = chunk_size
          reserve = (max_payload * RESERVE_FRACTION).ceil
          @chunk_bytes = ((max_payload - reserve) / EXPANSION).floor
          @chunk_bytes = [@chunk_bytes, chunk_size].min if chunk_size
          @reply_bytes = @chunk_bytes / REPLY_DIVISOR
        end

        # Whether the broker's limit leaves room for a chunk at all.
        def usable?
          @chunk_bytes >= MINIMUM_CHUNK
        end

        # The most a reply weighs on the wire under the same expansion.
        def reply_wire_bytes
          (@reply_bytes * EXPANSION).ceil
        end

        def summary
          cap = @chunk_size ? "chunk size #{@chunk_size}" : 'no chunk size'
          "chunks of #{@chunk_bytes} bytes and replies of #{@reply_bytes} bytes (broker limit #{@max_payload}, #{cap})"
        end
      end
    end
  end
end
