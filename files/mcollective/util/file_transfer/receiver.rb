# frozen_string_literal: true

require 'digest/sha2'
require 'fileutils'
require 'securerandom'
require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # One file out of the nodes it is given, each copy assembled under a
      # temporary name beside its destination, round by round through get,
      # digested as it is written, verified against the digest stat
      # reported, given the mode stat reported and renamed into place.
      # Answers the placed path per node and the failures. Reads no reply
      # itself and lists nothing.
      class Receiver
        TEMP_PREFIX = '.file_transfer-'

        # @param rpc [Rpc]
        # @param logger [#debug]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
        end

        # Receives the file from the nodes in destinations, as many at a
        # time as one download round allows.
        #
        # @param source [String] The path on every node
        # @param stats [Hash{String => Hash}] Identity to its stat reply data, which carries the
        #   size, digest and mode
        # @param destinations [Hash{String => String}] Identity to the local path its copy ends
        #   up at, whose directory exists
        # @return [Array(Hash{String => String}, Hash{String => Outcome})] The placed path per
        #   identity whose copy matched the digest, and the failures
        def receive_file(source, stats, destinations)
          placed = {}
          failures = {}
          destinations.keys.each_slice(@rpc.download_batch_size) do |group|
            group_placed, group_failures = receive_group(group, source, stats, destinations)
            placed.merge!(group_placed)
            failures.merge!(group_failures)
          end
          [placed, failures]
        end

        private

        # One round of nodes: a temporary file per node beside its
        # destination, made exclusively so nothing standing at the name is
        # adopted, then one round of get per offset for as long as a node's
        # reported size has bytes beyond the offset, each reply written and
        # digested as it comes, then for each node not failed the digest
        # compared with the one stat reported, the mode applied and the file
        # renamed into place. Whatever was not placed is removed at the end,
        # so a failed node or an interrupt leaves nothing beside the
        # destination.
        #
        # @param group [Array<String>] The identities of one round
        # @param source [String] The path on every node
        # @param stats [Hash{String => Hash}] Identity to its stat reply data
        # @param destinations [Hash{String => String}] Identity to the local path its copy ends up at
        # @return [Array(Hash{String => String}, Hash{String => Outcome})]
        def receive_group(group, source, stats, destinations)
          handles = {}
          digests = {}
          failures = {}
          placed = {}
          begin
            group.each do |identity|
              path = File.join(File.dirname(destinations[identity]), "#{TEMP_PREFIX}#{SecureRandom.hex(8)}")
              handles[identity] = File.new(path, File::RDWR | File::CREAT | File::EXCL | File::BINARY, 0o600)
              digests[identity] = Digest::SHA256.new
            rescue SystemCallError => e
              failures[identity] = write_failure(identity, destinations[identity], e)
            end
            pending = group - failures.keys
            offset = 0
            while (asking = pending.select { |identity| offset < stats[identity][:size] }).any?
              failures.merge!(fetch_round(asking, source, offset, handles, digests, stats))
              pending -= failures.keys
              offset += @rpc.message_data_bytes
            end
            pending.each do |identity|
              destination = destinations[identity]
              actual = digests[identity].hexdigest
              if actual != stats[identity][:sha256]
                failures[identity] = Outcome.failure(identity, :checksum_mismatch,
                  "#{source} on #{identity} changed during the download: expected #{stats[identity][:sha256]}, got #{actual}")
                next
              end

              # The permission bits the node reported with the owner's bits
              # added, under the umask, which is what net-scp's open gives a
              # downloaded file, and without the setuid, setgid and sticky
              # bits, which the node chose and this host has no use for.
              handles[identity].chmod(((stats[identity][:mode].to_i(8) & 0o777) | 0o600) & ~File.umask)
              # The close flushes what the writes buffered, so a full disk
              # can show here first.
              handles[identity].close
              File.rename(handles[identity].path, destination)
              placed[identity] = destination
            rescue SystemCallError => e
              failures[identity] = write_failure(identity, destination, e)
            end
          ensure
            handles.each do |identity, file|
              begin
                file.close
              rescue SystemCallError
                # The file is removed next, so a flush that fails here changes nothing.
              end
              FileUtils.rm_f(file.path) unless placed.key?(identity)
            end
          end
          [placed, failures]
        end

        # Asks the nodes for the chunk at one offset and writes each reply
        # to its node's file, feeding its digest. Returns the failures, the
        # write failures and the nodes the Response failed.
        #
        # @param asking [Array<String>] The identities asked this round
        # @param source [String] The path on every node
        # @param offset [Integer] The byte offset every node is asked for
        # @param handles [Hash{String => File}] Identity to its open temporary file
        # @param digests [Hash{String => Digest::SHA256}] Identity to the digest of what was written
        # @param stats [Hash{String => Hash}] Identity to its stat reply data
        # @return [Hash{String => Outcome}]
        def fetch_round(asking, source, offset, handles, digests, stats)
          failures = {}
          max_bytes = @rpc.message_data_bytes
          response = @rpc.call(asking, "file_transfer.get #{source}") { |client| client.get(path: source, offset: offset, max_bytes: max_bytes) }
          response.responded.each do |identity, data|
            content = data[:data].to_s.unpack1('m0')
            # The node decides what the reply says, so more content than
            # the request asked for is refused.
            raise "The reply carries #{content.bytesize} bytes, more than the #{max_bytes} requested" if content.bytesize > max_bytes

            # The copy is the file as its stat described it, so a reply
            # that reaches past that size, from a file that grew since,
            # is cut at it.
            remaining = stats[identity][:size] - offset
            slice = content.byteslice(0, remaining)
            handles[identity].write(slice)
            digests[identity].update(slice)
            # A regular file reads short only at its end, so a reply short
            # of the size stat reported means the file shrank in the
            # meantime, and the rounds up to that size would read nothing more.
            if content.bytesize < [max_bytes, remaining].min
              failures[identity] = Outcome.failure(identity, :transfer_failed,
                "#{source} on #{identity} replied with #{content.bytesize} bytes at offset #{offset} where #{remaining} remained, " \
                'so the file shrank during the download')
            end
          rescue StandardError => e
            @logger.debug(e.backtrace.join("\n"))
            failures[identity] = Outcome.failure(identity, :transfer_failed, "Writing #{source} from #{identity} failed: #{e.class}: #{e.message}")
          end
          failures.merge(response.errors)
        end

        # The failure of a node whose copy this host could not make, write
        # or place.
        #
        # @param identity [String]
        # @param destination [String] The local path the copy was to end up at
        # @param error [SystemCallError]
        # @return [Outcome]
        def write_failure(identity, destination, error)
          @logger.debug(error.backtrace.join("\n"))
          Outcome.failure(identity, :transfer_failed, "#{destination} could not be written from #{identity}: #{error.class}: #{error.message}")
        end
      end
    end
  end
end
