# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      OUTCOME_KINDS = [:no_response, :rpc_error, :rpc_failed, :transfer_failed, :payload_too_large, :checksum_mismatch].freeze

      # What a transfer did for one identity. A success carries the path the
      # file landed at, and a failure carries the kind and a message.
      Outcome = Data.define(:identity, :path, :kind, :message) do
        # @param identity [String]
        # @param path [String] The path the file landed at
        # @return [Outcome]
        def self.success(identity, path)
          new(identity: identity, path: path, kind: nil, message: nil)
        end

        # @param identity [String]
        # @param kind [Symbol] One of OUTCOME_KINDS
        # @param message [String]
        # @return [Outcome]
        # @raise [ArgumentError] For a kind that is not one of OUTCOME_KINDS
        def self.failure(identity, kind, message)
          raise ArgumentError, "Unknown outcome kind #{kind.inspect}" unless OUTCOME_KINDS.include?(kind)

          new(identity: identity, path: nil, kind: kind, message: message)
        end

        # A failure of the same kind for every identity, with the message
        # that the block returns for each.
        #
        # @param identities [Array<String>]
        # @param kind [Symbol] One of OUTCOME_KINDS
        # @yieldparam identity [String]
        # @yieldreturn [String] The message for that identity
        # @return [Hash{String => Outcome}]
        def self.failures(identities, kind)
          identities.to_h { |identity| [identity, failure(identity, kind, yield(identity))] }
        end

        # One Outcome per identity in the order given, its failure or a
        # success with its path. An identity with neither is a bug in the
        # caller, which fetch raises for.
        #
        # @param identities [Array<String>]
        # @param failed [Hash{String => Outcome}] The failure per identity that failed
        # @param paths [Hash{String => String}] The path per identity that succeeded
        # @return [Hash{String => Outcome}]
        def self.per_identity(identities, failed, paths)
          identities.to_h { |identity| [identity, failed[identity] || success(identity, paths.fetch(identity))] }
        end

        def success?
          kind.nil?
        end
      end
    end
  end
end
