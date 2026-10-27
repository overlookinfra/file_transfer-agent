# frozen_string_literal: true

require 'mcollective'
require_relative 'connection'
require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # Makes one call to the agent at a time and sorts each node's reply or
      # failure by identity. It knows what the broker allows per call, the data
      # one message contains and how many nodes it addresses at once. A reply
      # fails its node when its status code is 1 or missing, or when its data
      # isn't the hash of outputs the DDL promises. A code above 1 is an RPC
      # error and a missing reply is no_response. An exception fails every
      # identity of the call, and the gem raises one for a reply it can't
      # convert, such as null or a string for data.
      class Rpc
        AGENT = 'file_transfer'
        # Every reply of a download round arrives on the client's one broker
        # connection. nats-server stalls the senders when its unread backlog
        # passes 3/4 of 64 MiB and closes it past 64 MiB, and so does the
        # Choria broker. A round talks to this many nodes, whose replies at
        # the broker's limit of Connection::MAX_PAYLOAD stay under the stall
        # threshold.
        DOWNLOAD_BATCH_SIZE = 48

        # What one call returned. aborted contains the data of each status 1
        # reply, such as the digest the agent computed for a refused file.
        Response = Data.define(:responded, :errors, :aborted) do
          # @param errors [Hash{String => Outcome}] A failure per identity
          # @return [Response]
          def self.unsent(errors)
            new(responded: {}, errors: errors, aborted: {})
          end
        end

        # @param connection [Connection] Builds the RPC clients
        # @param logger [#debug, #info, #warn, #error]
        # @param rpc_timeout [Numeric] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node, raised to the agent's DDL timeout when that is longer
        # @param message_data_bytes [Integer] The data one message contains, which is the file content
        #   of a put or a get and the maximum size of a listing
        # @param upload_batch_size [Integer] How many nodes one chunk request is published to at once
        def initialize(connection, logger, rpc_timeout, message_data_bytes:, upload_batch_size:)
          @connection = connection
          @logger = logger
          @rpc_timeout = rpc_timeout
          @message_data_bytes = message_data_bytes
          @upload_batch_size = upload_batch_size
          @logger.debug("Each message contains up to #{message_data_bytes} bytes of data")
        end

        # @return [Integer] The data one message contains, in bytes
        attr_reader :message_data_bytes
        # @return [Integer] How many nodes one chunk request is published to at once
        attr_reader :upload_batch_size

        # Invokes the action the block calls on the yielded RPC client. One
        # timeout bounds both the wait for replies and publishing the call to
        # every node of a large group. A batch size sends the call to that many
        # identities at a time, in MCollective's batches without the pause
        # between them, each batch with its own publish and reply windows. The
        # connection's guard refuses any message over the broker's limit before
        # it is sent, which fails the identities with payload_too_large.
        #
        # @param identities [Array<String>] The nodes to address
        # @param context [String] Names the call in messages, such as "file_transfer.put app.tar"
        # @param batch_size [Integer, nil] Identities per batch, or nil for all of them at once
        # @yieldparam client [MCollective::RPC::Client] The client to call the action on
        # @return [Response]
        def call(identities, context, batch_size: nil, &block)
          return Response.unsent({}) if identities.empty?

          results = @connection.with_client(AGENT, identities, timeout: timeout, batch_size: batch_size, &block)
          sort_replies(results, identities, context)
        rescue PayloadTooLarge => e
          Response.unsent(Outcome.failures(identities, :payload_too_large) do |identity|
            "The #{context} request to #{identity} was not sent. #{e.message}. Lower the message data size."
          end)
        rescue StandardError => e
          @logger.error("The #{context} RPC call failed: #{e.class}: #{e.message}")
          @logger.debug(e.backtrace.join("\n"))
          Response.unsent(Outcome.failures(identities, :rpc_failed) { |identity| "The #{context} call failed on #{identity}: #{e.class}: #{e.message}" })
        end

        private

        # The wait for every call. A node's server stops the agent at its DDL
        # timeout and sends nothing after, so a node still working may take that
        # long to answer. The rpc timeout applies when it is longer.
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

        # The data of every identity that answered status 0 with a data hash, an
        # Outcome for every other identity, and the data hash of every status 1
        # reply. Only the first reply of an addressed identity counts.
        #
        # @param results [Array<Hash>] The results as the gem's client returns them
        # @param identities [Array<String>] The nodes that were addressed
        # @param context [String] Names the call in messages
        # @return [Response] responded, errors and aborted, each by identity
        def sort_replies(results, identities, context)
          expected = identities.to_set
          by_sender = {}
          results.each do |result|
            sender = result[:sender]
            if !expected.include?(sender)
              @logger.warn("Discarding #{context} response from unexpected sender #{sender.inspect}")
            elsif by_sender.key?(sender)
              @logger.warn("Ignoring another #{context} response from #{sender}, since only its first counts")
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
              errors[identity] = Outcome.failure(identity, :no_response,
                "No response from #{identity} for #{context} within #{timeout} seconds. If the node is up, its server may have " \
                "stopped the agent at the DDL timeout of #{ddl_timeout} seconds.")
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
          Response.new(responded: responded, errors: errors, aborted: aborted)
        end
      end
    end
  end
end
