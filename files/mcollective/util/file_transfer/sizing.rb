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
      # broker's payload limit, measured on the request the connector would
      # publish rather than modeled.
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
        def initialize(max_payload:, chunk_size:, rpc:, identity:)
          @max_payload = max_payload
          @chunk_size = chunk_size
          @rpc = rpc
          @identity = identity
          @budget = (max_payload * (1 - RESERVE_FRACTION)).floor
        end

        # The most content one put of this name to this destination may
        # carry, or 0 when even the minimum does not fit. The request is
        # measured at the cap and scaled to the budget's share of it until
        # it fits, which takes a few measurements since the request grows
        # almost in proportion to its content. A get reply carrying as much
        # weighs less, since the node signs nothing and sends no
        # certificate, so downloads ask for the same.
        def content_bytes(name, destination)
          content = @chunk_size || @budget
          while content >= MINIMUM_CHUNK && (wire = wire_bytes(content, name, destination)) > @budget
            content = [(content * @budget / wire.to_f).floor, content - 1].min
          end
          content < MINIMUM_CHUNK ? 0 : content
        end

        # The bytes the connector would publish for a final put of this
        # much content, the largest shape a chunk request takes.
        def wire_bytes(content, name, destination)
          @rpc.request_bytes({ session: 's' * 36, name: name, offset: MEASURED_OFFSET, data: ['x' * content].pack('m0'),
                               final: true, sha256: 'f' * 64, destination: destination, mode: '0777' }, @identity)
        end

        def summary
          cap = @chunk_size ? "chunk size #{@chunk_size}" : 'no chunk size'
          "#{@budget} usable bytes of the #{@max_payload} byte broker limit (#{cap})"
        end
      end
    end
  end
end
