# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # What a transfer did for one identity. A success contains the path the
      # file was written to, and a failure contains the error kind and message.
      Outcome = Data.define(:identity, :path, :error_kind, :error_message) do
        # @param identity [String]
        # @param path [String] The path the file was written to
        # @return [Outcome]
        def self.success(identity, path)
          new(identity: identity, path: path, error_kind: nil, error_message: nil)
        end

        # @param identity [String]
        # @param error_kind [Symbol] One of no_response, rpc_error, rpc_failed, transfer_failed, payload_too_large and checksum_mismatch
        # @param error_message [String]
        # @return [Outcome]
        def self.failure(identity, error_kind, error_message)
          new(identity: identity, path: nil, error_kind: error_kind, error_message: error_message)
        end

        # A failure of one kind for every identity, its message from the block.
        #
        # @param identities [Array<String>]
        # @param error_kind [Symbol] One of no_response, rpc_error, rpc_failed, transfer_failed, payload_too_large and checksum_mismatch
        # @yieldparam identity [String]
        # @yieldreturn [String] The error message for that identity
        # @return [Hash{String => Outcome}]
        def self.failures(identities, error_kind)
          identities.to_h { |identity| [identity, failure(identity, error_kind, yield(identity))] }
        end

        # One Outcome per identity in the order given, its failure or a success
        # with its path. fetch raises for one with neither, a bug in the caller.
        #
        # @param identities [Array<String>]
        # @param failed [Hash{String => Outcome}] The failure per identity that failed
        # @param paths [Hash{String => String}] The path per identity that succeeded
        # @return [Hash{String => Outcome}]
        def self.per_identity(identities, failed, paths)
          identities.to_h { |identity| [identity, failed[identity] || success(identity, paths.fetch(identity))] }
        end

        def success?
          error_kind.nil?
        end
      end
    end
  end
end
