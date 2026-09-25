# frozen_string_literal: true

require 'securerandom'
require_relative 'outcome'
require_relative 'transfer'

module MCollective
  module Util
    module FileTransfer
      # One session directory per node, created by mktemp on every identity
      # of a transfer and removed by cleanup. Files put into it without a
      # destination stay there until the cleanup, which is how a caller
      # delivers files a node uses in place and then removes them.
      class Session
        attr_reader :id, :paths

        # mktemp on the transfer's active identities. A node that named no
        # path is dropped from the transfer but kept for the cleanup, since
        # its mktemp did run.
        #
        # @param transfer [Transfer]
        # @param rpc [Rpc]
        # @param logger [#debug, #warn]
        # @param cleanup [Boolean, Hash{String => Boolean}] Whether the session is removed
        #   afterwards, for every node or per identity
        # @param sender [FileSender] Sends the files put into the session
        def self.create(transfer:, rpc:, logger:, cleanup:, sender:)
          id = SecureRandom.uuid
          response = rpc.call(transfer.active, 'file_transfer.mktemp') { |client| client.mktemp(session: id) }
          transfer.fail(response.errors)
          paths = response.responded.to_h { |identity, data| [identity, data[:path]] }
          pathless = paths.reject { |_identity, path| path.is_a?(String) && !path.empty? }.keys
          transfer.fail(Outcome.failures(pathless, :transfer_failed) { |identity| "file_transfer.mktemp on #{identity} answered without a session path" })
          logger.debug("Session #{id} created on #{paths.size} of #{transfer.count}")
          new(id, paths, transfer: transfer, rpc: rpc, logger: logger, cleanup: cleanup, sender: sender)
        end

        # Creates one session on the transfer's active identities, yields
        # it, and removes it afterwards on every node where it was created
        # and whose cleanup option is on.
        def self.with(transfer:, rpc:, logger:, cleanup:, sender:)
          return unless transfer.active?

          session = create(transfer: transfer, rpc: rpc, logger: logger, cleanup: cleanup, sender: sender)
          begin
            yield(session) if transfer.active?
          ensure
            session.cleanup unless session.paths.empty?
          end
        end

        # @param paths [Hash{String => String, nil}] The session path each identity's mktemp
        #   named, or nil when it named none
        def initialize(id, paths, transfer:, rpc:, logger:, cleanup:, sender:)
          @id = id
          @paths = paths
          @transfer = transfer
          @rpc = rpc
          @logger = logger
          @cleanup = cleanup
          @sender = sender
        end

        def active
          @transfer.active
        end

        def active?
          @transfer.active?
        end

        def failures
          @transfer.failures
        end

        # Sends one local file into the session on the identities, which
        # drop out of the session when it cannot be delivered to them.
        # Answers the identities that received the whole file.
        #
        # @param name [String] The path of the file relative to the session directory
        # @param mode [String, nil] Four octal digits, the source's own permission bits by default
        def put(local_path, name, identities: active, mode: nil)
          @sender.send_file(@id, local_path, name, identities.to_h { |identity| [identity, nil] }, mode: mode)
        end

        # Removes the session on every node in its paths whose cleanup
        # option is on.
        def cleanup
          to_clean, to_keep = @paths.keys.partition { |identity| cleanup?(identity) }
          to_keep.each do |identity|
            @logger.warn("Leaving session #{@id} on #{identity}, the file_transfer agent sweeps it after its stale_after setting")
          end
          return if to_clean.empty?

          response = @rpc.call(to_clean, 'file_transfer.cleanup') { |client| client.cleanup(session: @id) }
          response.errors.each do |identity, outcome|
            @logger.warn("Cleanup of session #{@id} on #{identity} failed: #{outcome.message}")
          end
          response.responded.each do |identity, data|
            next if data[:removed]
            # A node that named no path may never have made the session, so
            # its absence says nothing about the stale sweep.
            next if @paths[identity].nil?

            @logger.warn("Session #{@id} on #{identity} was gone before its cleanup. Another run's sweep or a manual " \
                         'removal took it, so check that stale_after on the node exceeds the longest task timeout.')
          end
        rescue StandardError => e
          @logger.warn("Cleanup of session #{@id} failed: #{e.class}: #{e.message}")
          @logger.debug(e.backtrace.join("\n")) if e.backtrace
        end

        private

        def cleanup?(identity)
          return @cleanup.fetch(identity, true) if @cleanup.is_a?(Hash)

          @cleanup
        end
      end
    end
  end
end
