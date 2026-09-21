# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # Logs through the MCollective logger. A caller with its own logging
      # gives the Client any object with these three methods instead.
      class DefaultLogger
        def initialize
          @warned = {}
        end

        def debug(message)
          MCollective::Log.debug(message)
        end

        def warn(message)
          MCollective::Log.warn(message)
        end

        # Warns once per id for the life of this logger, for a condition a
        # transfer would otherwise repeat for every chunk.
        def warn_once(id, message)
          return if @warned[id]

          @warned[id] = true
          warn(message)
        end
      end
    end
  end
end
