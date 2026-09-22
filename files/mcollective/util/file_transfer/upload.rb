# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # Sending a file or a tree to the same destination on every node,
      # chunk by chunk through put, with the last chunk verifying the file
      # and moving it into place.
      class Upload
        # How often a directory reached through a symbolic link may be sent
        # in a tree upload, since directories linking to each other are
        # reachable by many paths. A directory reached by its own path
        # always lands.
        WALK_REPEAT_LIMIT = 4

        def initialize(client)
          @client = client
          @rpc = client.rpc
          @logger = client.logger
          @chunk_size = client.chunk_size
        end

        # See Client#upload.
        def run(source, destination, identities)
          transfer = Transfer.start(identities, rpc: @rpc, logger: @logger, chunk_size: @chunk_size)
          landing = landing_paths(transfer, source, destination)
          Session.with(@client, transfer) do |session|
            if File.directory?(source)
              upload_tree(transfer, session.id, source, landing)
            else
              upload_file(transfer, session.id, source, File.basename(source), landing)
            end
          rescue SystemCallError => e
            # A source entry that cannot be read, such as a dangling link.
            transfer.fail(Outcome.failures(transfer.active, :transfer_failed) { "Reading #{source} failed: #{e.message}" })
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
        # following symbolic links as scp -r does. A directory is skipped
        # when it is already on its own ancestor chain, which ends a link
        # loop while a link and the directory it points at both land.
        # Directories that link to each other can still be reached by many
        # chains, so a directory reached through a link is walked at most
        # WALK_REPEAT_LIMIT times, which keeps a cross-linked tree from
        # multiplying the walk. A directory reached by its own path is
        # always walked, whatever the links to it sorted ahead of it did.
        def walk_local_tree(source)
          walked = Hash.new(0)
          queue = [['', source, [], false]]
          until queue.empty?
            relative, path, ancestors, via_link = queue.shift
            stat = File.stat(path)
            unless stat.directory?
              yield(relative, path, stat)
              next
            end

            real = File.realpath(path)
            next if ancestors.include?(real)

            walked[real] += 1
            if via_link && walked[real] > WALK_REPEAT_LIMIT
              @logger.warn_once("file_transfer_link_repeats_#{real}",
                "#{path} reaches a directory this upload has already sent #{WALK_REPEAT_LIMIT} times through links, so it " \
                'is skipped. Symbolic links between directories multiply what a tree upload sends.')
              next
            end

            yield(relative, path, stat)
            Dir.children(path).sort.each do |child|
              child_path = File.join(path, child)
              queue.push([relative.empty? ? child : File.join(relative, child), child_path, ancestors + [real],
                          via_link || File.lstat(child_path).symlink?])
            end
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

              unless transfer.sizing.usable?
                transfer.fail(transfer.payload_failures(identities, name, "chunks cannot shrink below #{Sizing::MINIMUM_CHUNK} bytes"))
                break
              end

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

              args = { session: session, name: name, offset: offset, data: FileTransfer.encode_chunk(chunk) }
              if offset + chunk.bytesize >= size
                sha256 = digest.dup.update(chunk).hexdigest
                delivered += send_final_chunk(transfer, identities, args, sha256, mode, landing, @rpc.final_timeout(size))
                next
              end

              outcome = send_chunk(transfer, identities, args, "file_transfer.put #{name}", @rpc.chunk_timeout(transfer))
              # A chunk the guard refused is sent again from the same offset at the new size.
              next if outcome == :resend

              digest.update(chunk)
              offset += chunk.bytesize
            end
          end
          delivered
        end

        # The final chunk carries the destination, which differs between the
        # nodes whose destination was a directory and the rest, so it goes
        # out once per distinct landing path. Answers the identities it
        # reached. A group whose chunk had to shrink stops the pass, since
        # the caller must read the chunk again at the new size before the
        # remaining groups get it.
        def send_final_chunk(transfer, identities, args, sha256, mode, landing, timeout)
          delivered = []
          identities.group_by { |identity| landing[identity] }.each do |destination, group|
            group &= transfer.active
            next if group.empty?

            final_args = args.merge(final: true, sha256: sha256, mode: mode)
            final_args[:destination] = destination if destination
            outcome = send_chunk(transfer, group, final_args, "file_transfer.put #{args[:name]} (final)", timeout)
            break if outcome == :resend

            delivered += group & transfer.active
          end
          delivered
        end

        # Sends one chunk to the identities. Answers :sent when the request
        # went out and the replies were applied, :resend when the chunk
        # shrank and the caller has to send it again. The publish guard
        # refuses a message over the broker's limit before it leaves the
        # client; a group that is silent but still answers a ping, or a
        # broker reconnect during a call that brought no reply, means the
        # message was too large for a hop the guard cannot see.
        def send_chunk(transfer, identities, args, context, timeout)
          reconnects_before = @rpc.wrapper_stat(:reconnects)
          refused = nil
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = @rpc.agent_call(identities, context, timeout: timeout) do |client|
            PublishHook.limit = transfer.sizing.max_payload
            begin
              client.put(args)
            rescue PayloadTooLarge => e
              refused = e
              []
            ensure
              PublishHook.limit = nil
            end
          end
          if refused
            transfer.shrink_after_guard(refused, identities)
            return :resend
          end

          transfer.record_chunk(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
          cause = @rpc.blind_failure(response, identities, reconnects_before)
          if cause
            transfer.shrink_blind(cause, identities)
            return :resend
          end

          transfer.fail(response[:errors])
          :sent
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
