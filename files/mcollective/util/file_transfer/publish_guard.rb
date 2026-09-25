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

      # Prepended onto the NATS wrapper class, the one object every request
      # in the process is published through, so that a message published
      # while a limit is set is refused when it is larger. Rpc sets the
      # limit for the duration of each call it makes, under the lock that
      # lets only one call publish at a time, and clears it after.
      module PublishGuard
        class << self
          attr_accessor :limit

          def install(wrapper_class)
            wrapper_class.prepend(self) unless wrapper_class.ancestors.include?(self)
          end
        end

        def publish(destination, payload, reply = nil)
          limit = PublishGuard.limit
          raise PayloadTooLarge.new(payload.bytesize, limit) if limit && payload.bytesize > limit

          super
        end
      end
    end
  end
end
