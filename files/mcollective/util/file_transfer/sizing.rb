# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # Raised by the publish guard before a message larger than the broker's
      # limit reaches the socket. The broker would otherwise close the
      # connection and the caller would only see a timeout.
      class PayloadTooLarge < StandardError
        def initialize(size, limit)
          super("A #{size} byte message exceeds the broker's #{limit} byte payload limit")
        end
      end

      # Prepended onto the NATS wrapper class so that every message published
      # while a chunk is sent passes through here, a message over the limit
      # is refused, and the largest one is remembered for the debug line
      # that checks the measured size against the sent one. The limit is
      # set only inside the connection's with_client, which serializes
      # calls, so no other request publishes meanwhile.
      module PublishHook
        class << self
          attr_accessor :limit, :largest

          def install(wrapper_class)
            wrapper_class.prepend(self) unless wrapper_class.ancestors.include?(self)
          end
        end
        self.largest = 0

        def publish(destination, payload, reply = nil)
          limit = PublishHook.limit
          if limit
            raise PayloadTooLarge.new(payload.bytesize, limit) if payload.bytesize > limit

            PublishHook.largest = [PublishHook.largest, payload.bytesize].max
          end

          super
        end
      end

      # How many bytes of file content one message may carry under the
      # broker's payload limit. The fixed parts of a request are measured
      # on one the connector would publish, the content is arithmetic on
      # the two base64 encodings it passes through, and the result is
      # confirmed on a request of that size.
      class Sizing
        DEFAULT_MAX_PAYLOAD = 1_048_576
        # Kept back from the limit for what the client cannot see, such as
        # the headers a federation broker rewrites in flight.
        RESERVE_FRACTION = 0.05
        MINIMUM_CHUNK = 16_384
        # Beyond any file's offset, so a measured request is at least as
        # large as any chunk of the content takes.
        MEASURED_OFFSET = 10**15

        attr_reader :max_payload, :budget

        # @param max_payload [Integer] The broker's advertised limit in bytes
        # @param chunk_size [Integer, nil] The most content a caller wants in one request, or nil
        #   for whatever the limit allows
        # @param rpc [Rpc] Builds the requests that are measured
        # @param identity [String] A node the measured requests are addressed to
        # @param logger [#warn_once] Told once when a request weighs more than computed
        def initialize(max_payload:, chunk_size:, rpc:, identity:, logger:)
          @max_payload = max_payload
          @chunk_size = chunk_size
          @rpc = rpc
          @identity = identity
          @logger = logger
          @budget = (max_payload * (1 - RESERVE_FRACTION)).floor
        end

        # What the connector's outer base64 makes of a signed request of
        # this many bytes: four characters per three bytes, and the newline
        # Base64.encode64 puts after every 60 characters, which the
        # transport JSON escapes to two.
        def self.encoded_bytes(signed_bytes)
          characters = 4 * ((signed_bytes + 2) / 3)
          characters + (2 * ((characters + 59) / 60))
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
        def content_bytes(name, destination)
          empty = measure(0, name, destination)
          room = @budget - (empty.wire_bytes - Sizing.encoded_bytes(empty.signed_bytes))
          return 0 if room < MINIMUM_CHUNK

          signed = room * 45 / 62
          signed -= 1 while Sizing.encoded_bytes(signed) > room
          signed += 1 while Sizing.encoded_bytes(signed + 1) <= room
          content = 3 * ((signed - empty.signed_bytes) / 4)
          content = [content, @chunk_size].min if @chunk_size
          content < MINIMUM_CHUNK ? 0 : confirm(content, name, destination)
        end

        # The bytes the connector would publish for a final put of this
        # much content, the largest shape a chunk request takes.
        def wire_bytes(content, name, destination)
          measure(content, name, destination).wire_bytes
        end

        def summary
          cap = @chunk_size ? "chunk size #{@chunk_size}" : 'no chunk size'
          "#{@budget} usable bytes of the #{@max_payload} byte broker limit (#{cap})"
        end

        private

        def measure(content, name, destination)
          @rpc.request_bytes({ session: 's' * 36, name: name, offset: MEASURED_OFFSET, data: ['x' * content].pack('m0'),
                               final: true, sha256: 'f' * 64, destination: destination, mode: '0777' }, @identity)
        end

        # Builds the request the content would go out in and answers the
        # content when it fits the budget. When it does not, the connector
        # frames requests differently than the arithmetic assumes, which is
        # said once, and the excess comes off the content, since a content
        # byte weighs more than one wire byte.
        def confirm(content, name, destination)
          wire = measure(content, name, destination).wire_bytes
          return content if wire <= @budget

          @logger.warn_once('file_transfer_sizing_mismatch',
            "A request of #{content} content bytes weighed #{wire} bytes against the #{@budget} computed for it, so the " \
            'connector frames requests differently than the sizing assumes and chunks are reduced by the difference')
          reduced = content - (wire - @budget)
          reduced < MINIMUM_CHUNK ? 0 : reduced
        end
      end
    end
  end
end
