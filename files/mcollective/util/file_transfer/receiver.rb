# frozen_string_literal: true

require 'digest/sha2'
require 'fileutils'
require 'securerandom'
require_relative 'outcome'
require_relative 'rpc'

module MCollective
  module Util
    module FileTransfer
      # Contains the workflow to receive one file from the nodes it is given.
      # Each copy is assembled chunk by chunk under a temporary name beside
      # its destination, verified against the digest the node reported, given
      # the reported mode, and then renamed into place.
      class Receiver
        # The mode a downloaded file or directory gets. It is the node's permission
        # bits plus the owner's, under the umask. The setuid, setgid and sticky bits
        # are dropped, since those are no longer relevant after transfer.
        #
        # @param reported [String] The mode as the node reported it, 3 or 4 octal digits
        # @param owner_bits [Integer] 0o600 for a file, 0o700 for a directory
        # @return [Integer]
        def self.local_mode(reported, owner_bits)
          ((reported.to_i(8) & 0o777) | owner_bits) & ~File.umask
        end

        # One node's file on its way in: the local path it ends up at, the
        # node's description of it, the temporary file it is assembled in and
        # the digest of what was written so far.
        Arrival = Data.define(:destination, :description, :file, :digest)

        # @param rpc [Rpc]
        # @param logger [#debug, #info, #warn, #error]
        def initialize(rpc:, logger:)
          @rpc = rpc
          @logger = logger
        end

        # Receives the file from the nodes, one download round at a time.
        #
        # @param source [String] The path on every node
        # @param descriptions [Hash{String => Hash}] Identity to its description, which contains the
        #   size, digest and mode
        # @param destinations [Hash{String => String}] Identity to the local path its copy ends
        #   up at, whose directory exists
        # @return [Hash{String => Outcome}] The failures. Every other node's copy matched the
        #   digest and is in place
        def receive_file(source, descriptions, destinations)
          failures = {}
          destinations.keys.each_slice(Rpc::DOWNLOAD_BATCH_SIZE) do |group|
            failures.merge!(receive_group(source, descriptions.slice(*group), destinations.slice(*group)))
          end
          failures
        end

        private

        # Receives the file for one round of nodes. Each node gets a temporary
        # file beside its destination, created exclusively so nothing already
        # at that name is reused. One get per chunk offset then goes to the
        # nodes whose reported size reaches past it, each reply written and
        # digested as it arrives. A node whose digest matches the one it
        # reported gets the mode applied and its file renamed into place. Any
        # temporary file not renamed is removed at the end, so a failed node
        # or an interrupt leaves nothing beside the destination.
        #
        # @param source [String] The path on every node
        # @param descriptions [Hash{String => Hash}] Identity to its description, for the round's nodes
        # @param destinations [Hash{String => String}] Identity to the local path its copy ends up at
        # @return [Hash{String => Outcome}] The failures
        def receive_group(source, descriptions, destinations)
          arrivals = {}
          failures = {}
          placed = []
          begin
            destinations.each do |identity, destination|
              path = File.join(File.dirname(destination), "#{TEMP_PREFIX}#{SecureRandom.hex(8)}")
              file = File.new(path, File::RDWR | File::CREAT | File::EXCL | File::BINARY, 0o600)
              arrivals[identity] = Arrival.new(destination: destination, description: descriptions[identity], file: file, digest: Digest::SHA256.new)
            rescue SystemCallError => e
              failures[identity] = write_failure(identity, destination, e)
            end
            offset = 0
            while (asking = arrivals.except(*failures.keys).select { |_identity, arrival| offset < arrival.description[:size] }).any?
              failures.merge!(fetch_round(source, offset, asking))
              offset += @rpc.message_data_bytes
            end
            arrivals.except(*failures.keys).each do |identity, arrival|
              actual = arrival.digest.hexdigest
              if actual != arrival.description[:sha256]
                failures[identity] = Outcome.failure(identity, :checksum_mismatch,
                  "#{source} on #{identity} changed during the download: expected #{arrival.description[:sha256]}, got #{actual}")
                next
              end

              arrival.file.chmod(Receiver.local_mode(arrival.description[:mode], 0o600))
              # The close flushes what the writes buffered, so a full disk
              # can show here first.
              arrival.file.close
              File.rename(arrival.file.path, arrival.destination)
              placed << identity
            rescue SystemCallError => e
              failures[identity] = write_failure(identity, arrival.destination, e)
            end
          ensure
            arrivals.each do |identity, arrival|
              begin
                arrival.file.close
              rescue SystemCallError
                # The file is removed next, so a flush that fails here changes nothing.
              end
              FileUtils.rm_f(arrival.file.path) unless placed.include?(identity)
            end
          end
          failures
        end

        # Gets the chunk at one offset from each node into its file and digest.
        # Returns the write failures together with the Response's failures.
        #
        # @param source [String] The path on every node
        # @param offset [Integer] The byte offset every node is asked for
        # @param arrivals [Hash{String => Arrival}] Identity to its arrival, for the nodes asked this round
        # @return [Hash{String => Outcome}]
        def fetch_round(source, offset, arrivals)
          failures = {}
          max_bytes = @rpc.message_data_bytes
          response = @rpc.call(arrivals.keys, "file_transfer.get #{source}") { |client| client.get(path: source, offset: offset, max_bytes: max_bytes) }
          response.responded.each do |identity, data|
            arrival = arrivals[identity]
            content = begin
              data[:data].to_s.unpack1('m0')
            rescue ArgumentError => e
              failures[identity] = Outcome.failure(identity, :transfer_failed, "#{source} on #{identity} replied with data that is not base64: #{e.message}")
              next
            end
            # The node decides what the reply says, so more content than
            # the request asked for is refused.
            if content.bytesize > max_bytes
              failures[identity] = Outcome.failure(identity, :transfer_failed,
                "#{source} on #{identity} replied with #{content.bytesize} bytes, more than the #{max_bytes} requested")
              next
            end

            # The copy is the file as its stat described it, so a reply
            # that reaches past that size, from a file that grew since,
            # is cut at it.
            remaining = arrival.description[:size] - offset
            slice = content.byteslice(0, remaining)
            arrival.file.write(slice)
            arrival.digest.update(slice)
            # A regular file reads short only at its end, so a reply short
            # of the size stat reported means the file shrank in the
            # meantime, and the rounds up to that size would read nothing more.
            if content.bytesize < [max_bytes, remaining].min
              failures[identity] = Outcome.failure(identity, :transfer_failed,
                "#{source} on #{identity} replied with #{content.bytesize} bytes at offset #{offset} where #{remaining} remained, " \
                'so the file shrank during the download')
            end
          rescue SystemCallError => e
            failures[identity] = Outcome.failure(identity, :transfer_failed, "Writing #{source} from #{identity} failed: #{e.class}: #{e.message}")
          end
          failures.merge(response.errors)
        end

        # A node's failure when this host can't make, write or place its copy.
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
