# frozen_string_literal: true

require_relative 'outcome'

module MCollective
  module Util
    module FileTransfer
      # The identities still taking part in one transfer and the failures
      # that removed the others.
      class Transfer
        attr_reader :identities, :active, :failures

        def initialize(identities)
          @identities = identities.dup
          @active = identities.dup
          @failures = {}
        end

        # @param outcomes [Hash{String => Outcome}] The failure of each identity to drop
        def fail(outcomes)
          dropped = @active & outcomes.keys
          dropped.each { |identity| @failures[identity] = outcomes[identity] }
          @active -= dropped
        end

        def active?
          !@active.empty?
        end

        # The identities as a count for log lines, such as "3 nodes".
        def count
          "#{@identities.size} #{@identities.size == 1 ? 'node' : 'nodes'}"
        end

        # One Outcome per identity, in the order the transfer was given
        # them. The block answers the delivered path of an identity that
        # was not failed, and nil for one nothing was delivered to.
        def outcomes
          @identities.to_h do |identity|
            outcome = @failures[identity]
            if outcome.nil?
              path = yield(identity)
              outcome = path ? Outcome.success(identity, path) : Outcome.failure(identity, :transfer_failed, "Nothing was delivered for #{identity}")
            end
            [identity, outcome]
          end
        end
      end
    end
  end
end
