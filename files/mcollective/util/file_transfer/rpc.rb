# frozen_string_literal: true

require 'mcollective'
require_relative 'outcome'
require_relative 'publish_guard'

module MCollective
  module Util
    module FileTransfer
      # One call to the file_transfer agent at a time, with every node's
      # reply or failure sorted by identity. Status code 1 is a failure for
      # every one of the agent's actions, a reply without a data hash is
      # one too, a code above 1 is an RPC error, a missing reply is
      # no_response, and an exception fails every identity.
      class Rpc
        AGENT = 'file_transfer'

        # What one call answered. The replies by identity under responded,
        # the failures by identity under errors as Outcomes, and the largest
        # message a guarded call published, 0 for an unguarded one or one
        # nothing could guard. The wire_bytes field is scaffolding for the
        # cluster run, to be removed before 1.0.0 ships.
        Response = Data.define(:responded, :errors, :wire_bytes) do
          def self.unsent(errors)
            new(responded: {}, errors: errors, wire_bytes: 0)
          end
        end

        attr_reader :rpc_timeout

        # @param connection [Connection] Builds the RPC clients
        # @param logger [#debug, #warn, #warn_once]
        # @param rpc_timeout [Numeric] Seconds to wait for every node's reply to one call, and to
        #   publish one call to every node
        def initialize(connection, logger, rpc_timeout)
          @connection = connection
          @logger = logger
          @rpc_timeout = rpc_timeout
          @guard = PublishGuard.new(connection, logger)
        end

        # The wait for a call that digests a whole file on the node, the
        # final put of a file and a stat with a checksum. The node's server
        # stops the agent at the timeout its DDL declares and answers
        # nothing after it, so that is the longest such a call can take,
        # and the rpc timeout applies only when it is longer.
        def digest_timeout
          [@rpc_timeout, ddl_timeout].max
        end

        # Invokes the action the block calls on the yielded RPC client and
        # answers the Response. The publish timeout is the rpc timeout, so
        # that one chunk reaches every node of a large group. A batch size
        # sends the call to that many identities at a time in MCollective's
        # batches without its pause between them, each batch with its own
        # publish and reply windows. A guard is the broker's limit, and a
        # message over it is refused before it leaves the client, which
        # fails the identities with payload_too_large.
        #
        # @param identities [Array<String>] The nodes to address
        # @param context [String] Names the call in messages, such as "file_transfer.put app.tar"
        # @param timeout [Numeric, nil] Seconds to wait for the replies, the rpc timeout by default
        # @return [Response]
        def call(identities, context, timeout: nil, batch_size: nil, guard: nil)
          return Response.unsent({}) if identities.empty?

          results = @connection.with_client(AGENT, identities, timeout: timeout || @rpc_timeout, publish_timeout: @rpc_timeout) do |client|
            if batch_size
              client.batch_size = batch_size
              client.batch_sleep_time = 0
            end
            guard ? @guard.guarding(guard) { yield client } : yield(client)
          end
          responded, errors = sort_replies(results, identities, context)
          Response.new(responded: responded, errors: errors, wire_bytes: guard ? @guard.largest_published : 0)
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

        # The timeout the agent's DDL declares, read from the DDL the client
        # loads, since the node enforces the value in its own copy.
        def ddl_timeout
          @ddl_timeout ||= DDL.new(AGENT).meta[:timeout]
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
