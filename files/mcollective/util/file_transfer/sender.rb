# frozen_string_literal: true

require 'digest/sha2'
require 'securerandom'
require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # One local file to the nodes, chunk by chunk through put under a
      # temporary name beside its destination, the last chunk verifying the
      # file on the node and renaming it into place, and abort to the nodes
      # that did not finish. Answers the failures among the nodes it was
      # given. Walks no trees and creates no directory.
      class Sender
        # Returns the permission bits of a stat as the four octal digits that
        # put and mkdir take.
        #
        # @param stat [File::Stat]
        # @return [String]
        def self.permission_bits(stat)
          format('%04o', stat.mode & 0o7777)
        end

        # @param rpc [Rpc]
        # @param logger [#warn]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
        end

        # Sends the file to the identities in destinations, which maps each
        # of them to the path the file ends up at, with the source's own
        # mode. Returns the failures among them; the rest received the
        # whole file. Every chunk carries its destination, which names the
        # directory of the temporary file, and one token per file, which
        # names the file. Nothing resends a chunk, so a node that was sent
        # a chunk and did not finish is told to abort, which removes its
        # temporary file, unless its own agent refused a chunk and removed
        # the file already.
        #
        # @param source [String] The local file to send
        # @param destinations [Hash{String => String}]
        # @return [Hash{String => Outcome}]
        def send_file(source, destinations)
          stat = File.stat(source)
          # Opening a named pipe blocks until something writes to it, so
          # only a regular file is opened.
          return Outcome.failures(destinations.keys, :transfer_failed) { "#{source} is not a regular file" } unless stat.file?

          token = SecureRandom.hex(8)
          pending = destinations.keys
          failures = {}
          refused = []
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

                args = { token: token, offset: offset, data: [chunk].pack('m0') }
                digest.update(chunk)
                if offset + chunk.bytesize >= size
                  # The recorded size bounds the sending whatever the file
                  # does in the meantime. The digest covers the bytes that
                  # were read, so a file with bytes beyond that size, or one
                  # rewritten at the same size, would verify on the node as a
                  # copy of neither version.
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
                step, step_refused = send_chunk(pending, destinations, args)
                failures.merge!(step)
                refused.concat(step_refused)
                pending -= failures.keys
                finished = args[:final] == true
                break if finished || pending.empty?

                offset += chunk.bytesize
              end
            end
          rescue SystemCallError => e
            # A source that cannot be read, such as a dangling link in a tree.
            failures.merge!(Outcome.failures(pending, :transfer_failed) { "Reading #{source} failed: #{e.class}: #{e.message}" })
          ensure
            if started
              unfinished = failures.keys - refused
              unfinished += pending unless finished
              send_abort(destinations.slice(*unfinished), token) unless unfinished.empty?
            end
          end
          failures
        end

        private

        # Sends one chunk to the identities, once per distinct destination
        # since the destination names the temporary file's directory, and a
        # batch of nodes per request. Returns the failures and the nodes
        # whose agent refused the chunk, which removed the file itself. A
        # final chunk refused while reporting a digest other than the one
        # sent is a checksum mismatch.
        #
        # @param identities [Array<String>] The nodes to send to
        # @param destinations [Hash{String => String}] Identity to the path the file ends up at
        # @param args [Hash] The put arguments of the chunk, without the destination
        # @return [Array(Hash{String => Outcome}, Array<String>)]
        def send_chunk(identities, destinations, args)
          failures = {}
          refused = []
          identities.group_by { |identity| destinations[identity] }.each do |destination, group|
            context = "file_transfer.put #{destination}#{' (final)' if args[:final]}"
            response = @rpc.call(group, context, batch_size: @rpc.upload_batch_size) { |client| client.put(args.merge(destination: destination)) }
            refused.concat(response.aborted.keys)
            response.errors.each do |identity, outcome|
              actual = response.aborted.dig(identity, :sha256)
              mismatch = args[:sha256] && actual.is_a?(String) && actual != args[:sha256]
              failures[identity] = mismatch ? Outcome.failure(identity, :checksum_mismatch, outcome.message) : outcome
            end
          end
          [failures, refused]
        end

        # Tells the nodes to remove the temporary file of a file that will
        # not finish, grouped by destination like the chunks. A node whose
        # abort fails or stays silent keeps the file until someone removes
        # it, which is a warning, since the node's own failure is already
        # the one in the outcome.
        #
        # @param destinations [Hash{String => String}] Identity to the path the file was for
        # @param token [String] The token that names the temporary file
        def send_abort(destinations, token)
          destinations.group_by { |_identity, destination| destination }.each do |destination, pairs|
            identities = pairs.map(&:first)
            response = @rpc.call(identities, "file_transfer.abort #{destination}") { |client| client.abort(destination: destination, token: token) }
            response.errors.each do |identity, outcome|
              @logger.warn("The temporary file .file_transfer-#{token} beside #{destination} stays on #{identity}: #{outcome.message}")
            end
          end
        end
      end
    end
  end
end
