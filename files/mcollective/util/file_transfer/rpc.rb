# frozen_string_literal: true

require 'mcollective'
require_relative 'connection'
require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # Makes one call to the file_transfer agent at a time and sorts every
      # node's reply or failure by identity. It also knows what the broker
      # allows a call: the payload limit every message is held under, the
      # data one message carries, and how many nodes one call addresses at
      # once. Status code 1 is a failure for every one of the agent's
      # actions, and so is a reply without a status code or with an array
      # for data. A code above 1 is an RPC error, a missing reply is
      # no_response, and an exception fails every identity of the call,
      # which is where a reply the gem itself cannot convert ends, one with
      # null or a string for data.
      class Rpc
        AGENT = 'file_transfer'
        DEFAULT_MAX_PAYLOAD = 1_048_576
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

        # What one call returned. aborted holds the data of each status 1
        # reply, such as the digest the agent computed for a refused file.
        Response = Data.define(:responded, :errors, :aborted) do
          # @param errors [Hash{String => Outcome}] A failure per identity
          # @return [Response]
          def self.unsent(errors)
            new(responded: {}, errors: errors, aborted: {})
          end
        end

        # @param connection [Connection] Builds the RPC clients and reads the broker's limit
        # @param logger [#debug, #warn, #warn_once]
        # @param rpc_timeout [Numeric] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node, raised to the agent's DDL timeout when that is longer
        # @param message_data_kib [Integer, nil] The caller's choice of data per message in
        #   kibibytes, or nil
        # @param upload_batch_size [Integer, nil] The caller's choice of nodes per chunk request, or nil
        def initialize(connection, logger, rpc_timeout, message_data_kib: nil, upload_batch_size: nil)
          @connection = connection
          @logger = logger
          @rpc_timeout = rpc_timeout
          @message_data_kib = message_data_kib
          @upload_batch_size = upload_batch_size
        end

        # The payload limit the broker advertised, or the default with a
        # warning that names why it could not be read. The first call reads
        # it after its client has connected, since the connector has no
        # server info before then, so a size asked for before any call is
        # an error rather than a guess.
        #
        # @return [Integer] Bytes
        # @raise [RuntimeError] Before the first call
        def max_payload
          @max_payload || raise('No call has run yet, so the broker message size limit has not been read')
        end

        # The data one message carries, in bytes, which is the file content
        # of a put or a get and the most a listing may weigh. The caller's
        # choice, or half the broker's limit, which leaves the other half
        # for the envelope and the base64 passes around the data. Asked for
        # after an operation's first call, which reads the limit.
        #
        # @return [Integer]
        def message_data_bytes
          @message_data_bytes ||= begin
            bytes = @message_data_kib ? @message_data_kib * 1024 : max_payload / 2
            @logger.debug("Each message carries up to #{bytes} bytes of data")
            bytes
          end
        end

        # How many nodes one chunk request is published to at once, the
        # caller's choice or the largest number that keeps a batch under
        # UPLOAD_BATCH_BYTES.
        #
        # @return [Integer]
        def upload_batch_size
          @upload_batch_size || [UPLOAD_BATCH_BYTES / max_payload, 1].max
        end

        # How many nodes one download round asks at once, the largest number
        # that keeps one round of replies, each at most the broker's limit,
        # under the broker's stall threshold.
        #
        # @return [Integer]
        def download_batch_size
          [(BROKER_PENDING_LIMIT * BROKER_STALL_FRACTION / max_payload).floor, 1].max
        end

        # Invokes the action the block calls on the yielded RPC client and
        # returns the Response. The wait, for the replies and for publishing
        # the call to every node of a large group alike, is the one timeout.
        # A batch size sends the call to that many identities at a time, in
        # MCollective's batches without the pause between them, each batch
        # with its own publish and reply windows. Every message the call
        # publishes is checked against the broker's limit. One over the
        # limit is refused before it leaves the client, which fails the
        # identities with payload_too_large.
        #
        # @param identities [Array<String>] The nodes to address
        # @param context [String] Names the call in messages, such as "file_transfer.put app.tar"
        # @param batch_size [Integer, nil] Identities per batch, or nil for all of them at once
        # @yieldparam client [MCollective::RPC::Client] The client to call the action on
        # @return [Response]
        def call(identities, context, batch_size: nil)
          return Response.unsent({}) if identities.empty?

          results = @connection.with_client(AGENT, identities, timeout: timeout, publish_timeout: timeout) do |client|
            if batch_size
              client.batch_size = batch_size
              client.batch_sleep_time = 0
            end
            @max_payload ||= read_max_payload
            @connection.guard(max_payload) { yield client }
          end
          responded, errors, aborted = sort_replies(results, identities, context)
          Response.new(responded: responded, errors: errors, aborted: aborted)
        rescue PayloadTooLarge => e
          Response.unsent(Outcome.failures(identities, :payload_too_large) do |identity|
            "The #{context} request to #{identity} was not sent. #{e.message}. Lower the message data size."
          end)
        rescue StandardError => e
          @logger.warn("The #{context} RPC call failed: #{e.class}: #{e.message}")
          @logger.debug(e.backtrace.join("\n"))
          Response.unsent(Outcome.failures(identities, :rpc_failed) { |identity| "The #{context} call failed on #{identity}: #{e.class}: #{e.message}" })
        end

        private

        # The wait for every call. The node's server stops the agent at the
        # timeout that its DDL declares and sends nothing after that, so a
        # node still working on a request may take that long to answer, and
        # the rpc timeout applies when it is longer.
        #
        # @return [Numeric] Seconds
        def timeout
          @timeout ||= [@rpc_timeout, ddl_timeout].max
        end

        # The timeout that the agent's DDL declares, read from the DDL that
        # the client loads, since the node enforces the value in its own copy.
        #
        # @return [Integer] Seconds
        def ddl_timeout
          @ddl_timeout ||= DDL.new(AGENT).meta[:timeout]
        end

        # Reads the limit from the server info of the client that has just
        # connected, or falls back to the default.
        #
        # @return [Integer] Bytes
        def read_max_payload
          limit = @connection.max_payload
          if limit.is_a?(Integer) && limit.positive?
            @logger.debug("The broker limits a message to #{limit} bytes")
            limit
          else
            unknown_max_payload("the server info says #{limit.inspect}")
          end
        rescue StandardError => e
          unknown_max_payload("#{e.class}: #{e.message}")
        end

        def unknown_max_payload(reason)
          @logger.warn_once('file_transfer_max_payload_unknown',
            "The file transfer client could not read the broker's message size limit (#{reason}) and assumes " \
            "#{DEFAULT_MAX_PAYLOAD} bytes")
          DEFAULT_MAX_PAYLOAD
        end

        # The message for a node that stayed silent. A silence may be the
        # node's server stopping the agent at the DDL timeout, which the
        # message names.
        #
        # @param identity [String]
        # @param context [String] Names the call in messages
        # @return [String]
        def silence_message(identity, context)
          "No response from #{identity} for #{context} within #{timeout} seconds. If the node is up, its server may have " \
            "stopped the agent at the DDL timeout of #{ddl_timeout} seconds."
        end

        # Returns the data of every identity that answered with status 0 and
        # a data hash, an Outcome for every other identity, and the data hash
        # of every reply with status 1. Only the first reply of an identity
        # counts, and only from the identities that were addressed.
        #
        # @param results [Array<Hash>] The results as the gem's client returns them
        # @param identities [Array<String>] The nodes that were addressed
        # @param context [String] Names the call in messages
        # @return [Array(Hash, Hash, Hash)] responded, errors and aborted, each by identity
        def sort_replies(results, identities, context)
          expected = identities.to_set
          by_sender = {}
          results.each do |result|
            sender = result[:sender]
            if !expected.include?(sender)
              @logger.warn("Discarding #{context} response from unexpected sender #{sender.inspect}")
            elsif by_sender.key?(sender)
              @logger.warn("Ignoring duplicate #{context} response from #{sender}")
            else
              by_sender[sender] = result
            end
          end

          responded = {}
          errors = {}
          aborted = {}
          identities.each do |identity|
            result = by_sender[identity]
            if result.nil?
              errors[identity] = Outcome.failure(identity, :no_response, silence_message(identity, context))
            elsif !result[:statuscode].is_a?(Integer)
              errors[identity] = Outcome.failure(identity, :transfer_failed, "The #{context} call on #{identity} answered without a status code")
            elsif result[:statuscode] > 1
              errors[identity] = Outcome.failure(identity, :rpc_error,
                "The #{context} call on #{identity} returned RPC error: #{result[:statusmsg]} (code #{result[:statuscode]})")
            elsif result[:statuscode] == 1
              errors[identity] = Outcome.failure(identity, :transfer_failed, "The #{context} call on #{identity} failed: #{result[:statusmsg]}")
              aborted[identity] = result[:data] if result[:data].is_a?(Hash)
            elsif !result[:data].is_a?(Hash)
              errors[identity] = Outcome.failure(identity, :transfer_failed, "The #{context} call on #{identity} answered without usable data")
            else
              responded[identity] = result[:data]
            end
          end
          [responded, errors, aborted]
        end
      end
    end
  end
end
