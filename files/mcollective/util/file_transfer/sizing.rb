# frozen_string_literal: true

require 'json'
require 'mcollective'
require_relative 'outcome'
require_relative 'rpc'

module MCollective
  module Util
    module FileTransfer
      # How much content one put request may carry under the broker's
      # payload limit, and how many nodes one call goes to at once. The
      # size of a request is computed from its layers as the gem builds
      # them, each serialized here from the same values with the same
      # serializer, so no request is measured and nothing is held back:
      # the body of RPC::Client#new_request, the envelope and the secure
      # request of Security::Choria#encoderequest, the base64 with line
      # breaks of SSL.base64_encode, and the transport message of the NATS
      # connector, with the target list a federation broker is sent.
      class Sizing
        DEFAULT_MAX_PAYLOAD = 1_048_576
        MINIMUM_CHUNK = 16_384
        # The digits of a 64-bit count, which the request counter in the
        # reply subject cannot reach, so the subject is sized for any run.
        COUNTER_DIGITS = 20
        # The connector puts this many targets into one federated message.
        FEDERATION_GROUP = 200
        # Every reply of a download round lands on the client's one broker
        # connection. nats-server closes a connection whose unread backlog
        # passes this many bytes, after stalling the senders above the
        # fraction below, and the Choria broker keeps both, so one round of
        # replies stays under the stall threshold.
        BROKER_PENDING_LIMIT = 64 * 1024 * 1024
        BROKER_STALL_FRACTION = 0.75
        # The client keeps a copy of a chunk request for every node of an
        # upload batch in memory until the flusher has written it, so a
        # batch is bounded to this many bytes at the broker's limit unless
        # the caller chose its own size.
        UPLOAD_BATCH_BYTES = 256 * 1024 * 1024

        # @param connection [Connection] Reads the broker's limit and the values the request layers carry
        # @param logger [#warn_once] Told once when the limit cannot be read or a download batch is reduced
        # @param chunk_size [Integer, nil] The most content a caller wants in one request, or nil
        #   for whatever the limit allows
        # @param upload_batch_size [Integer, nil] The caller's choice of nodes per chunk request, or nil
        # @param download_batch_size [Integer, nil] The caller's choice of nodes per download round, or nil
        def initialize(connection, logger, chunk_size:, upload_batch_size:, download_batch_size:)
          @connection = connection
          @logger = logger
          @chunk_size = chunk_size
          @upload_batch_size = upload_batch_size
          @download_batch_size = download_batch_size
        end

        # What the connector's outer base64 makes of a signed request of
        # this many bytes: four characters per three bytes, and the newline
        # Base64.encode64 puts after every 60 characters, which the
        # transport JSON escapes to two.
        def self.encoded_bytes(signed_bytes)
          characters = 4 * ((signed_bytes + 2) / 3)
          characters + (2 * ((characters + 59) / 60))
        end

        # The broker's advertised payload limit, read once, or the default
        # with a warning naming why it could not be read.
        def max_payload
          @max_payload ||= read_max_payload
        end

        # The most content one put of this name to these destinations may
        # carry to these identities, or 0 when even the minimum does not
        # fit. The transport message around the encoded request has to fit
        # the limit, so the content is what the largest signed request
        # whose encoding fits beside that framing leaves beyond the signed
        # request with no content, in base64 groups of four characters per
        # three bytes. A get reply carrying as much weighs less, since the
        # node signs nothing and sends no certificate, so downloads ask for
        # the same.
        #
        # @param name [String] The name the chunks are put under
        # @param destinations [Array<String, nil>] The paths the file lands at, nil where it stays in the session
        # @param identities [Array<String>] The nodes the chunks go to
        # @param size [Integer] The file size, which bounds the digits of the offsets
        def content_bytes(name, destinations, identities, size)
          empty = secure_bytes(name, destinations.compact.max_by(&:bytesize), largest_offset(size))
          signed = largest_signed(max_payload - framing_bytes(identities))
          content = 3 * ((signed - empty) / 4)
          content = [content, @chunk_size].min if @chunk_size
          content < MINIMUM_CHUNK ? 0 : content
        end

        # The bytes the connector would publish for a final put of this
        # much content, the largest shape a chunk request takes.
        def wire_bytes(content, name, destination, identities, size)
          signed = secure_bytes(name, destination, largest_offset(size)) + (4 * ((content + 2) / 3))
          framing_bytes(identities) + Sizing.encoded_bytes(signed)
        end

        # How many nodes one chunk request is published to at once, the
        # caller's choice or as many as keep a batch under UPLOAD_BATCH_BYTES.
        def upload_batch_size
          @upload_batch_size || [UPLOAD_BATCH_BYTES / max_payload, 1].max
        end

        # How many nodes one download round asks at once, as many as keep
        # one round of replies of the given wire size under the broker's
        # stall threshold, or the caller's smaller choice.
        def download_batch_size(reply_wire)
          bounded = [(BROKER_PENDING_LIMIT * BROKER_STALL_FRACTION / reply_wire).floor, 1].max
          return bounded if @download_batch_size.nil?
          return @download_batch_size if @download_batch_size <= bounded

          @logger.warn_once('file_transfer_download_batch_bounded',
            "The download batch size of #{@download_batch_size} is reduced to #{bounded} so one round of replies stays " \
            "under three quarters of the #{BROKER_PENDING_LIMIT} bytes the broker holds for a connection before closing it")
          bounded
        end

        # A payload_too_large failure per identity for a file whose
        # content_bytes came out as 0, for an upload or a download.
        #
        # @return [Hash{String => Outcome}]
        def too_small_failures(identities, name, direction)
          per, verb = direction == :upload ? ['request', 'sent to'] : ['reply', 'fetched from']
          Outcome.failures(identities, :payload_too_large) do |identity|
            "The broker's payload limit of #{max_payload} bytes leaves less than #{MINIMUM_CHUNK} bytes of file content " \
              "per #{per}, so #{name} cannot be #{verb} #{identity}"
          end
        end

        def summary
          cap = @chunk_size ? "chunk size #{@chunk_size}" : 'no chunk size'
          "a #{max_payload} byte broker limit (#{cap})"
        end

        private

        def read_max_payload
          limit = @connection.max_payload
          return limit if limit.is_a?(Integer) && limit.positive?

          unknown_max_payload("the server info says #{limit.inspect}")
        rescue StandardError => e
          unknown_max_payload("#{e.class}: #{e.message}")
        end

        def unknown_max_payload(reason)
          @logger.warn_once('file_transfer_max_payload_unknown',
            "The file transfer client could not read the broker's message size limit (#{reason}) and assumes " \
            "#{DEFAULT_MAX_PAYLOAD} bytes")
          DEFAULT_MAX_PAYLOAD
        end

        def signing
          @signing ||= @connection.signing(Rpc::AGENT)
        end

        # The largest offset any chunk of a file this size is put at.
        def largest_offset(size)
          [size - 1, 0].max
        end

        # The signed request of a final put with no content, built from the
        # same hashes as RPC::Client#new_request and
        # Security::Choria#encoderequest with the same serializer. The
        # session, request id, and digest are placeholders of their fixed
        # lengths, and the time has the digits of now.
        def secure_bytes(name, destination, offset)
          data = { session: 'x' * 36, name: name, offset: offset, data: '', final: true, sha256: 'x' * 64, mode: '0777',
                   destination: destination }.compact
          body = JSON.dump(agent: Rpc::AGENT, action: 'put', caller: signing.callerid, data: data)
          filter = Util.empty_filter
          filter['agent'] << Rpc::AGENT
          envelope = JSON.dump(protocol: 'choria:request:1', message: body,
            envelope: { requestid: 'x' * 32, senderid: signing.identity, callerid: signing.callerid, filter: filter,
                        collective: signing.collective, agent: Rpc::AGENT, ttl: signing.ttl, time: Time.now.to_i })
          JSON.dump(protocol: 'choria:secure:request:1', message: envelope, signature: signing.signature, pubcert: signing.pubcert).bytesize
        end

        # The transport message around the encoded request, with the data
        # empty, as the connector builds it for a connected broker, and
        # through a federation broker with the targets of the message in
        # its headers. The reply subject is sized for the largest counter,
        # and the targets are the longest identities a message can carry,
        # which bounds every message the connector makes of the call.
        def framing_bytes(identities)
          reply = "#{signing.collective}.reply.#{'x' * 32}.#{Process.pid}.#{'9' * COUNTER_DIGITS}"
          headers = { 'mc_sender' => signing.identity, 'reply-to' => reply }
          if signing.federated
            targets = identities.max_by(FEDERATION_GROUP, &:bytesize).map { |identity| "#{signing.collective}.node.#{identity}" }
            headers = { 'federation' => { 'target' => targets, 'req' => 'x' * 32 } }.merge(headers)
          end
          JSON.dump('protocol' => 'choria:transport:1', 'data' => '', 'headers' => headers).bytesize
        end

        # The largest signed request whose encoding fits the room the
        # framing leaves under the limit. encoded_bytes grows by 62 for
        # every 45 signed bytes, so the seed is close and the two loops
        # settle on the exact largest.
        def largest_signed(room)
          return 0 if room <= 0

          signed = room * 45 / 62
          signed -= 1 while signed.positive? && Sizing.encoded_bytes(signed) > room
          signed += 1 while Sizing.encoded_bytes(signed + 1) <= room
          signed
        end
      end
    end
  end
end
