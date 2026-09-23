# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # Sending a file or a tree to the same destination on every node,
      # chunk by chunk through put, with the last chunk verifying the file
      # and moving it into place.
      class Upload
        def initialize(client)
          @client = client
          @rpc = client.rpc
          @logger = client.logger
          @chunk_size = client.chunk_size
          @upload_batch_size = client.upload_batch_size
        end

        # See Client#upload.
        def run(source, destination, identities)
          transfer = Transfer.start(identities, rpc: @rpc, logger: @logger, chunk_size: @chunk_size)
          @logger.debug("Upload chunks go to #{transfer.upload_batch_size(@upload_batch_size)} nodes per request")
          landing = landing_paths(transfer, source, destination)
          Session.with(@client, transfer) do |session|
            if File.directory?(source)
              upload_tree(transfer, session.id, source, landing)
            else
              upload_file(transfer, session.id, source, File.basename(source), landing)
            end
          rescue SystemCallError => e
            # A source entry that cannot be read, such as a dangling link.
            transfer.fail(Outcome.failures(transfer.active, :transfer_failed) { "Reading #{source} failed: #{e.class}: #{e.message}" })
          end
          transfer.outcomes { |identity| landing[identity] }
        end

        # Where the upload lands on each node.
        def landing_paths(transfer, source, destination)
          response = @rpc.agent_call(transfer.active, "file_transfer.stat #{destination}") { |client| client.stat(path: destination) }
          transfer.fail(response[:errors])
          response[:responded].to_h do |identity, data|
            [identity, data[:type] == 'directory' ? File.join(destination, File.basename(source)) : destination]
          end
        end

        def upload_tree(transfer, session, source, landing)
          walk_local_tree(source) do |relative, local_path, stat|
            break unless transfer.active?

            remote = landing.transform_values { |base| relative.empty? ? base : File.join(base, relative) }
            if stat.directory?
              mkdir_remote(transfer, remote, permission_bits(stat))
            else
              upload_file(transfer, session, local_path, relative, remote)
            end
          end
        end

        # Yields every entry of a local tree, parents before their contents,
        # in the order Find lists them. A symbolic link to a file is sent as
        # the file it points at. Find does not descend into a symbolic link
        # to a directory, and the walk skips it with a warning, so it cannot
        # loop. The source itself is resolved first, so a link to a
        # directory can still be the source.
        def walk_local_tree(source)
          root = File.realpath(source)
          Find.find(root, ignore_error: false) do |path|
            if File.symlink?(path) && File.directory?(path)
              @logger.warn("Skipping #{path}, a symbolic link to a directory")
              next
            end

            relative = Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
            yield(relative == '.' ? '' : relative, path, File.stat(path))
          end
        end

        # One mkdir per distinct remote path, since a call carries one set
        # of arguments to every node.
        def mkdir_remote(transfer, remote, mode)
          remote.slice(*transfer.active).group_by { |_identity, path| path }.each do |path, pairs|
            identities = pairs.map(&:first)
            response = @rpc.agent_call(identities, "file_transfer.mkdir #{path}") { |client| client.mkdir(path: path, mode: mode) }
            transfer.fail(response[:errors])
          end
        end

        # Sends one file into the session chunk by chunk, verifying and
        # moving it into place with the last chunk. landing maps each
        # identity that receives the file to the path it ends up at, or to
        # nil when it stays in the session. The file keeps the source's mode
        # unless one is given. Answers the identities that received the
        # whole file.
        def upload_file(transfer, session, local_path, name, landing, mode: nil)
          stat = File.stat(local_path)
          size = stat.size
          mode ||= permission_bits(stat)
          digest = Digest::SHA256.new
          delivered = []
          offset = 0
          File.open(local_path, 'rb') do |file|
            loop do
              identities = (landing.keys & transfer.active) - delivered
              break if identities.empty?

              requested = transfer.sizing.chunk_bytes
              file.seek(offset)
              chunk = file.read(requested) || ''
              # A regular file reads short only at its end, so a short read
              # before the recorded size means the source shrank meanwhile.
              if chunk.bytesize < requested && offset + chunk.bytesize < size
                transfer.fail(Outcome.failures(identities, :transfer_failed) do |identity|
                  "#{local_path} shrank below the #{size} bytes it had when the upload to #{identity} started"
                end)
                break
              end

              args = { session: session, name: name, offset: offset, data: [chunk].pack('m0') }
              if offset + chunk.bytesize >= size
                sha256 = digest.dup.update(chunk).hexdigest
                delivered += send_final_chunk(transfer, identities, args, sha256, mode, landing, @rpc.final_timeout(size))
                next
              end

              send_chunk(transfer, identities, args, "file_transfer.put #{name}", @rpc.chunk_timeout(transfer))
              digest.update(chunk)
              offset += chunk.bytesize
            end
          end
          delivered
        end

        # The final chunk carries the destination, which differs between the
        # nodes whose destination was a directory and the rest, so it goes
        # out once per distinct landing path. Answers the identities it
        # reached.
        def send_final_chunk(transfer, identities, args, sha256, mode, landing, timeout)
          delivered = []
          identities.group_by { |identity| landing[identity] }.each do |destination, group|
            group &= transfer.active
            next if group.empty?

            final_args = args.merge(final: true, sha256: sha256, mode: mode)
            final_args[:destination] = destination if destination
            send_chunk(transfer, group, final_args, "file_transfer.put #{args[:name]} (final)", timeout)
            delivered += group & transfer.active
          end
          delivered
        end

        # Sends one chunk to the identities, a batch of them per request,
        # and applies the replies. The publish guard refuses a message over
        # the broker's limit before it leaves the client, which fails those
        # identities with the chunk size named as the remedy.
        def send_chunk(transfer, identities, args, context, timeout)
          batch_size = transfer.upload_batch_size(@upload_batch_size)
          refused = nil
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = @rpc.agent_call(identities, context, timeout: timeout, batch_size: batch_size) do |client|
            @rpc.guarding(transfer.sizing.max_payload) { client.put(args) }
          rescue PayloadTooLarge => e
            refused = e
            []
          end
          if refused
            transfer.fail(Outcome.failures(identities, :payload_too_large) do |identity|
              "#{context} on #{identity} was not sent because #{refused.message}. Lower the chunk size."
            end)
            return
          end

          # The batches go out one after the other, so the time of one of
          # them is what the next chunk timeout is derived from.
          batches = identities.size.fdiv(batch_size).ceil
          transfer.record_chunk((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / batches)
          transfer.fail(response[:errors])
          log_wire_size(context, args)
        end

        # The wire size of the chunk request against its content, read off
        # a debug log to check the expansion the sizing assumes. The content
        # size comes back from the strict base64 of the data.
        def log_wire_size(context, args)
          wire = @rpc.largest_published
          return unless wire.positive?

          content = (args[:data].bytesize / 4 * 3) - args[:data].count('=')
          @logger.debug("#{context} weighed #{wire} bytes on the wire for #{content} bytes of content")
        end

        # The permission bits of a stat as the four octal digits put and
        # mkdir take.
        def permission_bits(stat)
          format('%04o', stat.mode & 0o7777)
        end
      end
    end
  end
end
