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
      # calls, so no other request publishes meanwhile. The largest message
      # is scaffolding for the cluster run, to be removed before 1.0.0
      # ships together with largest_published below.
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

      # Runs a call with the hook set to the broker's limit, so a message
      # over it raises PayloadTooLarge before it leaves the client instead
      # of making the broker close the connection.
      class PublishGuard
        def initialize(connection, logger)
          @connection = connection
          @logger = logger
        end

        # Runs the block under the limit. Without a wrapper to hook the
        # block still runs, after a warning that the guard is off.
        def guarding(limit)
          install
          PublishHook.limit = limit
          PublishHook.largest = 0
          yield
        ensure
          PublishHook.limit = nil
        end

        # The largest message the last guarded call published, or 0 when
        # no wrapper could be hooked. Scaffolding for the cluster run, to
        # be removed before 1.0.0 ships.
        def largest_published
          PublishHook.largest
        end

        private

        def install
          wrapper = @connection.nats_wrapper
          if wrapper.class.method_defined?(:publish)
            PublishHook.install(wrapper.class)
          else
            unavailable("#{wrapper.inspect} has no publish method")
          end
        rescue StandardError => e
          unavailable("#{e.class}: #{e.message}")
        end

        def unavailable(reason)
          @logger.warn_once('file_transfer_guard_unavailable',
            "The file transfer client cannot check its requests against the broker's message size limit (#{reason}), " \
            'so a request over it would drop the connection instead of failing')
        end
      end
    end
  end
end
