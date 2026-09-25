# frozen_string_literal: true

require 'digest/sha2'
require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # Sends one local file into a session on the nodes, chunk by chunk
      # through put, with the last chunk verifying the file and moving it
      # into place.
      class FileSender
        # The permission bits of a stat as the four octal digits put and
        # mkdir take.
        def self.permission_bits(stat)
          format('%04o', stat.mode & 0o7777)
        end

        # @param transfer [Transfer] The nodes still taking part, which drop out as chunks fail
        # @param rpc [Rpc]
        # @param sizing [Sizing]
        # @param logger [#debug]
        def initialize(transfer:, rpc:, sizing:, logger:)
          @transfer = transfer
          @rpc = rpc
          @sizing = sizing
          @logger = logger
        end

        # Sends the file to the identities in landing that are still
        # active. landing maps each identity to the path the file ends up
        # at, or to nil when it stays in the session. The file keeps the
        # source's mode unless one is given. Answers the identities that
        # received the whole file.
        #
        # @param session_id [String] The session the chunks are put into
        # @param name [String] The path of the file relative to the session directory
        # @param landing [Hash{String => String, nil}]
        # @param mode [String, nil] Four octal digits
        # @return [Array<String>]
        def send_file(session_id, local_path, name, landing, mode: nil)
          identities = landing.keys & @transfer.active
          return [] if identities.empty?

          # Measured against the longest destination, the largest request
          # any chunk of the file takes.
          requested = @sizing.content_bytes(name, landing.values.compact.max_by(&:bytesize) || name, identities.first)
          if requested.zero?
            @transfer.fail(@sizing.too_small_failures(identities, name, :upload))
            return []
          end
          @logger.debug("#{name} goes in chunks of #{requested} bytes")
          stat = File.stat(local_path)
          size = stat.size
          mode ||= FileSender.permission_bits(stat)
          digest = Digest::SHA256.new
          delivered = []
          offset = 0
          File.open(local_path, 'rb') do |file|
            loop do
              identities = (landing.keys & @transfer.active) - delivered
              break if identities.empty?

              chunk = file.read(requested) || ''
              # A regular file reads short only at its end, so a short read
              # before the recorded size means the source shrank meanwhile.
              if chunk.bytesize < requested && offset + chunk.bytesize < size
                @transfer.fail(Outcome.failures(identities, :transfer_failed) do |identity|
                  "#{local_path} shrank below the #{size} bytes it had when the upload to #{identity} started"
                end)
                break
              end

              args = { session: session_id, name: name, offset: offset, data: [chunk].pack('m0') }
              if offset + chunk.bytesize >= size
                sha256 = digest.dup.update(chunk).hexdigest
                delivered += send_final_chunk(identities, args, sha256, mode, landing)
                next
              end

              send_chunk(identities, args, "file_transfer.put #{name}")
              digest.update(chunk)
              offset += chunk.bytesize
            end
          end
          delivered
        end

        private

        # The final chunk carries the destination, which differs between the
        # nodes whose destination was a directory and the rest, so it goes
        # out once per distinct landing path. The node digests the whole
        # file before it answers, so the call waits the digest timeout.
        # Answers the identities it reached.
        def send_final_chunk(identities, args, sha256, mode, landing)
          delivered = []
          identities.group_by { |identity| landing[identity] }.each do |destination, group|
            group &= @transfer.active
            next if group.empty?

            final_args = args.merge(final: true, sha256: sha256, mode: mode)
            final_args[:destination] = destination if destination
            send_chunk(group, final_args, "file_transfer.put #{args[:name]} (final)", timeout: @rpc.digest_timeout)
            delivered += group & @transfer.active
          end
          delivered
        end

        # Sends one chunk to the identities, a batch of them per request,
        # under the publish guard, and applies the replies.
        def send_chunk(identities, args, context, timeout: nil)
          response = @rpc.call(identities, context, timeout: timeout, batch_size: @sizing.upload_batch_size,
            guard: @sizing.max_payload) { |client| client.put(args) }
          @transfer.fail(response.errors)
          log_wire_size(context, args, response.wire_bytes)
        end

        # The wire size of the chunk request against its content, read off
        # a debug log to check the expansion the sizing assumes. The content
        # size comes back from the strict base64 of the data. Scaffolding
        # for the cluster run, to be removed before 1.0.0 ships.
        def log_wire_size(context, args, wire)
          return unless wire.positive?

          content = (args[:data].bytesize / 4 * 3) - args[:data].count('=')
          @logger.debug("#{context} weighed #{wire} bytes on the wire for #{content} bytes of content")
        end
      end
    end
  end
end
