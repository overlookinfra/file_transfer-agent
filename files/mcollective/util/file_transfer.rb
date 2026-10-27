# frozen_string_literal: true

require_relative 'file_transfer/client'
require_relative 'file_transfer/connection'
require_relative 'file_transfer/download'
require_relative 'file_transfer/local_path'
require_relative 'file_transfer/outcome'
require_relative 'file_transfer/receiver'
require_relative 'file_transfer/rpc'
require_relative 'file_transfer/sender'
require_relative 'file_transfer/upload'

module MCollective
  module Util
    # The client side of the file_transfer agent.
    # Client and Outcome are the public surface.
    module FileTransfer
      VERSION = '1.0.0'
      # The name every temporary file starts with, on a node beside a put's
      # destination and here beside a download's.
      TEMP_PREFIX = '.file_transfer-'
    end
  end
end
