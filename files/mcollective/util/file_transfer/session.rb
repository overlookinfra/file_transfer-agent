# frozen_string_literal: true

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
        def self.create(client, transfer)
          id = SecureRandom.uuid
          response = client.rpc.agent_call(transfer.active, 'file_transfer.mktemp') { |rpc_client| rpc_client.mktemp(session: id) }
          transfer.fail(response[:errors])
          paths = response[:responded].to_h { |identity, data| [identity, data[:path]] }
          pathless = paths.reject { |_identity, path| path.is_a?(String) && !path.empty? }.keys
          transfer.fail(Outcome.failures(pathless, :transfer_failed) { |identity| "file_transfer.mktemp on #{identity} answered without a session path" })
          client.logger.debug("Session #{id} created on #{FileTransfer.count(paths)}")
          new(client, id, transfer, paths)
        end

        # Creates one session on the transfer's active identities, yields
        # it, and removes it afterwards on every node where it was created
        # and whose cleanup option is on.
        def self.with(client, transfer)
          return unless transfer.active?

          session = create(client, transfer)
          begin
            yield(session) if transfer.active?
          ensure
            session.cleanup unless session.paths.empty?
          end
        end

        # @param paths [Hash{String => String, nil}] The session path each identity's mktemp
        #   named, or nil when it named none
        def initialize(client, id, transfer, paths)
          @client = client
          @id = id
          @transfer = transfer
          @paths = paths
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
          Upload.new(@client).upload_file(@transfer, @id, local_path, name, identities.to_h { |identity| [identity, nil] }, mode: mode)
        end

        # Removes the session on every node in its paths whose cleanup
        # option is on, after reporting the transfer's chunk reductions.
        def cleanup
          @transfer.report_reductions
          to_clean, to_keep = @paths.keys.partition { |identity| @client.cleanup?(identity) }
          to_keep.each do |identity|
            @client.logger.warn("Leaving session #{@id} on #{identity}, the file_transfer agent sweeps it after its stale_after setting")
          end
          return if to_clean.empty?

          response = @client.rpc.agent_call(to_clean, 'file_transfer.cleanup') { |rpc_client| rpc_client.cleanup(session: @id) }
          response[:errors].each do |identity, outcome|
            @client.logger.warn("Cleanup of session #{@id} on #{identity} failed: #{outcome.message}")
          end
          response[:responded].each do |identity, data|
            next if data[:removed]
            # A node that named no path may never have made the session, so
            # its absence says nothing about the stale sweep.
            next if @paths[identity].nil?

            @client.logger.warn("Session #{@id} on #{identity} was gone before its cleanup. Another run's sweep or a manual " \
                                'removal took it, so check that stale_after on the node exceeds the longest task timeout.')
          end
        rescue StandardError => e
          @client.logger.warn("Cleanup of session #{@id} failed: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
