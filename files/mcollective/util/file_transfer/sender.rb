# frozen_string_literal: true

require 'digest/sha2'
require 'securerandom'
require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # One local file sent to the nodes, chunk by chunk, through put under a
      # temporary name beside its destination. The last chunk verifies the
      # file on the node and renames it into place. Unfinished nodes get an
      # abort. Returns the failures. Walks no trees and creates no directory.
      class Sender
        # A stat's permission bits as the 4 octal digits put and mkdir take.
        #
        # @param stat [File::Stat]
        # @return [String]
        def self.permission_bits(stat)
          format('%04o', stat.mode & 0o7777)
        end

        # @param rpc [Rpc]
        # @param logger [#debug, #info, #warn, #error]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
        end

        # Sends the file with the source's own mode to each identity's path in
        # destinations. Returns the failures, and the rest received the whole file.
        # Each chunk is sent with its destination, naming the temporary file's
        # directory, and one token per file, naming the file. Nothing resends a
        # chunk, so a node that was sent a chunk and did not finish gets an
        # abort, which removes its temporary file if there is one. The agent
        # removes the file itself when its own put fails. A status 1 reply can
        # also come from the node's server, for a request it refused or an agent
        # it killed, so the abort goes out either way.
        #
        # @param source [String] The local file to send
        # @param stat [File::Stat] The source's stat, whose size bounds the sending and whose
        #   mode the copy gets
        # @param destinations [Hash{String => String}]
        # @return [Hash{String => Outcome}] The failures
        def send_file(source, stat, destinations)
          # Opening a named pipe blocks until something writes to it, so
          # only a regular file is opened.
          return Outcome.failures(destinations.keys, :transfer_failed) { "#{source} is not a regular file" } unless stat.file?

          token = SecureRandom.hex(8)
          pending = destinations.keys
          failures = {}
          started = false
          finished = false
          begin
            size = stat.size
            data_bytes = @rpc.message_data_bytes
            digest = Digest::SHA256.new
            offset = 0
            File.open(source, 'rb') do |file|
              loop do
                chunk = file.read(data_bytes) || ''
                # A regular file reads short only at its end, so a short read
                # before the recorded size means the source shrank in the meantime.
                if chunk.bytesize < data_bytes && offset + chunk.bytesize < size
                  failures.merge!(Outcome.failures(pending, :transfer_failed) do |identity|
                    "#{source} shrank below the #{size} bytes it had when the upload to #{identity} started"
                  end)
                  break
                end

                final = offset + chunk.bytesize >= size
                args = { token: token, offset: offset, data: [chunk].pack('m0') }
                digest.update(chunk)
                if final
                  # The node's digest check can't catch a source that changed
                  # while it was read, since the digest is of the bytes sent.
                  # A file grown past the recorded size or rewritten at the same
                  # size would pass as a copy of neither version, so the source
                  # is checked once more before the final chunk goes.
                  now = file.stat
                  if !file.eof? || now.size != size || now.mtime != stat.mtime
                    failures.merge!(Outcome.failures(pending, :transfer_failed) do |identity|
                      "#{source} changed while it was being uploaded to #{identity}, so the copy was not finished"
                    end)
                    break
                  end

                  args.merge!(final: true, sha256: digest.hexdigest, mode: Sender.permission_bits(stat))
                end

                started = true
                failures.merge!(send_chunk(pending, destinations, args))
                pending -= failures.keys
                finished = final
                break if finished || pending.empty?

                offset += chunk.bytesize
              end
            end
          rescue SystemCallError => e
            # A source that can't be opened or read.
            failures.merge!(Outcome.failures(pending, :transfer_failed) { "Reading #{source} failed: #{e.class}: #{e.message}" })
          ensure
            if started
              unfinished = failures.keys
              unfinished += pending unless finished
              send_abort(destinations.slice(*unfinished), token) unless unfinished.empty?
            end
          end
          failures
        end

        private

        # Sends one chunk once per distinct destination, since that names the
        # temporary file's directory, and to a batch of nodes per request. A
        # refused final chunk reporting another digest is a checksum mismatch.
        #
        # @param identities [Array<String>] The nodes to send to
        # @param destinations [Hash{String => String}] Identity to the path the file ends up at
        # @param args [Hash] The put arguments of the chunk, without the destination
        # @return [Hash{String => Outcome}] The failures
        def send_chunk(identities, destinations, args)
          failures = {}
          identities.group_by { |identity| destinations[identity] }.each do |destination, group|
            context = "file_transfer.put #{destination}#{' (final)' if args[:final]}"
            response = @rpc.call(group, context, batch_size: @rpc.upload_batch_size) { |client| client.put(args.merge(destination: destination)) }
            response.errors.each do |identity, outcome|
              actual = response.aborted.dig(identity, :sha256)
              mismatch = args[:sha256] && actual.is_a?(String) && actual != args[:sha256]
              failures[identity] = mismatch ? Outcome.failure(identity, :checksum_mismatch, outcome.error_message) : outcome
            end
          end
          failures
        end

        # Tells the nodes to remove an unfinished file's temporary file, grouped
        # by destination like the chunks. A node whose abort fails or stays
        # silent may keep the file until someone removes it. That is a warning,
        # since the outcome already contains the node's own failure.
        #
        # @param destinations [Hash{String => String}] Identity to the path the file was for
        # @param token [String] The token that names the temporary file
        def send_abort(destinations, token)
          destinations.keys.group_by { |identity| destinations[identity] }.each do |destination, identities|
            response = @rpc.call(identities, "file_transfer.abort #{destination}") { |client| client.abort(destination: destination, token: token) }
            response.errors.each do |identity, outcome|
              @logger.warn("The temporary file #{TEMP_PREFIX}#{token} beside #{destination} may remain on #{identity}, since its abort failed: " \
                           "#{outcome.error_message}")
            end
          end
        end
      end
    end
  end
end
