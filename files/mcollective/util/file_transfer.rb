# frozen_string_literal: true

require_relative 'file_transfer/client'
require_relative 'file_transfer/connection'
require_relative 'file_transfer/default_logger'
require_relative 'file_transfer/download'
require_relative 'file_transfer/local_path'
require_relative 'file_transfer/outcome'
require_relative 'file_transfer/receiver'
require_relative 'file_transfer/rpc'
require_relative 'file_transfer/sender'
require_relative 'file_transfer/upload'

module MCollective
  module Util
    # The client side of the file_transfer agent. A Client moves files to
    # and from nodes in chunks that fit the broker's payload limit and
    # verifies every file with SHA-256. Each file is assembled under a
    # temporary name beside its destination, on the node for an upload and
    # on this host for a download, until its last chunk verifies it and it
    # is renamed into place.
    # Nodes are addressed by Choria identity, and every call returns an
    # Outcome per identity rather than raising for one node's failure.
    # Client and Outcome are the public surface. The README describes the
    # options and logger contracts and walks the files in reading order.
    module FileTransfer
      VERSION = '1.0.0'
    end
  end
end
