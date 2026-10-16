# frozen_string_literal: true

require 'mcollective'

module MCollective
  module Util
    module FileTransfer
      # Logs through the MCollective logger. A caller with its own logging
      # gives the Client any object with these two methods instead.
      class DefaultLogger
        def debug(message)
          MCollective::Log.debug(message)
        end

        def warn(message)
          MCollective::Log.warn(message)
        end
      end
    end
  end
end
