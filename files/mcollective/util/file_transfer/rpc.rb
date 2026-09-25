# frozen_string_literal: true

require 'mcollective'
require_relative 'outcome'
require_relative 'publish_guard'

module MCollective
  module Util
    module FileTransfer
      # One call to the file_transfer agent at a time, with every node's
      # reply or failure sorted by identity, and what the broker allows a
      # call: the payload limit every message is held under, and how many
      # nodes one call addresses at once. Status code 1 is a failure for
      # every one of the agent's actions, a reply without a data hash is
      # one too, a code above 1 is an RPC error, a missing reply is
      # no_response, and an exception fails every identity.
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

        # What one call answered: the replies by identity under responded
        # and the failures by identity under errors as Outcomes.
        Response = Data.define(:responded, :errors) do
          def self.unsent(errors)
            new(responded: {}, errors: errors)
          end
        end

        attr_reader :rpc_timeout

        # @param connection [Connection] Builds the RPC clients and reads the broker's limit
        # @param logger [#debug, #warn, #warn_once]
        # @param rpc_timeout [Numeric] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node
        # @param upload_batch_size [Integer, nil] The caller's choice of nodes per chunk request, or nil
        # @param download_batch_size [Integer, nil] The caller's choice of nodes per download round, or nil
        def initialize(connection, logger, rpc_timeout, upload_batch_size: nil, download_batch_size: nil)
          @connection = connection
          @logger = logger
          @rpc_timeout = rpc_timeout
          @upload_batch_size = upload_batch_size
          @download_batch_size = download_batch_size
        end

        # The wait for a call that digests a whole file on the node, the
        # final put of a file and a stat with a checksum. The node's server
        # stops the agent at the timeout its DDL declares and answers
        # nothing after it, so that is the longest such a call can take,
        # and the rpc timeout applies only when it is longer.
        def digest_timeout
          [@rpc_timeout, ddl_timeout].max
        end

        # The broker's advertised payload limit, read once, or the default
        # with a warning naming why it could not be read.
        def max_payload
          @max_payload ||= read_max_payload
        end

        # How many nodes one chunk request is published to at once, the
        # caller's choice or as many as keep a batch under UPLOAD_BATCH_BYTES.
        def upload_batch_size
          @upload_batch_size || [UPLOAD_BATCH_BYTES / max_payload, 1].max
        end

        # How many nodes one download round asks at once, as many as keep
        # one round of replies, each at most the broker's limit, under the
        # broker's stall threshold, or the caller's smaller choice.
        def download_batch_size
          bounded = [(BROKER_PENDING_LIMIT * BROKER_STALL_FRACTION / max_payload).floor, 1].max
          return bounded if @download_batch_size.nil?
          return @download_batch_size if @download_batch_size <= bounded

          @logger.warn_once('file_transfer_download_batch_bounded',
            "The download batch size of #{@download_batch_size} is reduced to #{bounded} so one round of replies stays " \
            "under three quarters of the #{BROKER_PENDING_LIMIT} bytes the broker holds for a connection before closing it")
          bounded
        end

        # Invokes the action the block calls on the yielded RPC client and
        # answers the Response. The publish timeout is the rpc timeout, so
        # that one chunk reaches every node of a large group. A batch size
        # sends the call to that many identities at a time in MCollective's
        # batches without its pause between them, each batch with its own
        # publish and reply windows. Every message the call publishes is
        # checked against the broker's limit, and one over it is refused
        # before it leaves the client, which fails the identities with
        # payload_too_large.
        #
        # @param identities [Array<String>] The nodes to address
        # @param context [String] Names the call in messages, such as "file_transfer.put app.tar"
        # @param timeout [Numeric, nil] Seconds to wait for the replies, the rpc timeout by default
        # @return [Response]
        def call(identities, context, timeout: nil, batch_size: nil)
          return Response.unsent({}) if identities.empty?

          results = @connection.with_client(AGENT, identities, timeout: timeout || @rpc_timeout, publish_timeout: @rpc_timeout) do |client|
            if batch_size
              client.batch_size = batch_size
              client.batch_sleep_time = 0
            end
            guarded { yield client }
          end
          responded, errors = sort_replies(results, identities, context)
          Response.new(responded: responded, errors: errors)
        rescue PayloadTooLarge => e
          Response.unsent(Outcome.failures(identities, :payload_too_large) do |identity|
            "#{context} on #{identity} was not sent. #{e.message}. Lower the chunk size."
          end)
        rescue StandardError => e
          @logger.warn("#{context} RPC call failed: #{e.class}: #{e.message}")
          @logger.debug(e.backtrace.join("\n")) if e.backtrace
          Response.unsent(Outcome.failures(identities, :rpc_failed) { |identity| "#{context} failed on #{identity}: #{e.class}: #{e.message}" })
        end

        private

        # Runs the block with the guard set to the broker's limit.
        def guarded
          PublishGuard.install(@connection.nats_wrapper.class)
          PublishGuard.limit = max_payload
          yield
        ensure
          PublishGuard.limit = nil
        end

        # The timeout the agent's DDL declares, read from the DDL the client
        # loads, since the node enforces the value in its own copy.
        def ddl_timeout
          @ddl_timeout ||= DDL.new(AGENT).meta[:timeout]
        end

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

        # The data of every identity that answered with status 0 and a data
        # hash, and an Outcome for every other identity.
        def sort_replies(results, identities, context)
          by_sender = index_by_sender(results, identities, context)
          responded = {}
          errors = {}
          identities.each do |identity|
            result = by_sender[identity]
            if result.nil?
              errors[identity] = Outcome.failure(identity, :no_response, "No response from #{identity} for #{context}")
            elsif result[:statuscode] > 1
              errors[identity] = Outcome.failure(identity, :rpc_error,
                "#{context} on #{identity} returned RPC error: #{result[:statusmsg]} (code #{result[:statuscode]})")
            elsif result[:statuscode] == 1
              errors[identity] = Outcome.failure(identity, :transfer_failed, "#{context} on #{identity} failed: #{result[:statusmsg]}")
            elsif !result[:data].is_a?(Hash)
              errors[identity] = Outcome.failure(identity, :transfer_failed, "#{context} on #{identity} answered without usable data")
            else
              responded[identity] = result[:data]
            end
          end
          [responded, errors]
        end

        # The first reply per identity, from the identities addressed only.
        def index_by_sender(results, identities, context)
          expected = identities.to_set
          by_sender = {}
          results.each do |result|
            sender = result[:sender]
            if sender.nil?
              @logger.warn("Discarding #{context} response with nil sender")
            elsif !expected.include?(sender)
              @logger.warn("Discarding #{context} response from unexpected sender #{sender.inspect}")
            elsif by_sender.key?(sender)
              @logger.warn("Ignoring duplicate #{context} response from #{sender}")
            else
              by_sender[sender] = result
            end
          end
          by_sender
        end
      end
    end
  end
end
