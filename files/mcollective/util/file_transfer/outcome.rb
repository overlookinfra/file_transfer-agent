# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      OUTCOME_KINDS = [:no_response, :rpc_error, :rpc_failed, :transfer_failed, :payload_too_large, :checksum_mismatch].freeze

      # What a transfer did for one identity. A success carries the path the
      # file landed at, a failure the kind and a message.
      Outcome = Data.define(:identity, :path, :kind, :message) do
        def self.success(identity, path)
          new(identity: identity, path: path, kind: nil, message: nil)
        end

        def self.failure(identity, kind, message)
          raise ArgumentError, "Unknown outcome kind #{kind.inspect}" unless OUTCOME_KINDS.include?(kind)

          new(identity: identity, path: nil, kind: kind, message: message)
        end

        # A failure of the same kind for every identity, with the message
        # the block answers for each.
        def self.failures(identities, kind)
          identities.to_h { |identity| [identity, failure(identity, kind, yield(identity))] }
        end

        def success?
          kind.nil?
        end
      end
    end
  end
end
