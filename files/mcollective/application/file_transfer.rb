# frozen_string_literal: true

require 'mcollective'
require_relative '../util/file_transfer'

module MCollective
  class Application
    # The mco file_transfer command, a plain client of the agent through the
    # library the module ships with it. MCollective derives the class name
    # from the command name, hence the underscore.
    class File_transfer < Application # rubocop:disable Naming/ClassAndModuleCamelCase
      # The library's warnings, such as an entry skipped in a tree or a
      # temporary file left on a node, are for the person at the terminal,
      # so they go to stderr beside the per node lines rather than to the
      # MCollective log, which a client config may send nowhere.
      class TerminalLogger < Util::FileTransfer::DefaultLogger
        # Kernel#warn prints nothing under -W0, and these lines are not
        # Ruby warnings.
        def warn(message)
          $stderr.puts(message) # rubocop:disable Style/StderrPuts
        end
      end

      description 'Move files to and from nodes through the file_transfer agent'

      usage <<~END_OF_USAGE
        mco file_transfer [OPTIONS] [FILTERS] upload SOURCE DESTINATION
        mco file_transfer [OPTIONS] [FILTERS] download SOURCE DIRECTORY

        upload sends a local file or directory tree to DESTINATION on every node.
        download fetches SOURCE from every node into a directory under DIRECTORY
        named after the node, such as DIRECTORY/web1.example.net/app.log.
      END_OF_USAGE

      option :message_data_size,
        arguments: ['--message-data-size KIBIBYTES'],
        description: 'Data per request in kibibytes, the file content of a chunk and the most a directory listing may ' \
                     'weigh. Without it, 512, half the Choria broker message size limit of 1 MiB, which has no setting. A request ' \
                     'over the limit fails its node with payload_too_large, and a reply over it never arrives, so the ' \
                     'node shows as no_response.',
        type: Integer

      option :upload_batch_size,
        arguments: ['--upload-batch-size NODES'],
        description: 'How many nodes one chunk request is published to at once. Without it, 256, which keeps one batch of ' \
                     'requests under 256 MiB of memory on this host at the broker message size limit.',
        type: Integer

      option :rpc_timeout,
        arguments: ['--rpc-timeout SECONDS'],
        description: 'Seconds to wait for every node\'s reply to one call, and to publish one call to every node. Without it, ' \
                     'the library\'s 300 seconds. The wait is never shorter than the agent\'s DDL timeout, 120 seconds. ' \
                     'mco\'s own --timeout has no effect on this command, and --discovery-timeout bounds the discovery of ' \
                     'the nodes.',
        type: Integer

      # Takes the command and its two paths from the remaining arguments.
      #
      # @param configuration [Hash] The application's configuration, filled in here
      def post_option_parser(configuration)
        raise 'Please specify upload or download, a source, and a destination' unless ARGV.length == 3

        configuration[:command], configuration[:source], configuration[:destination] = ARGV.shift(3)
      end

      # @param configuration [Hash] The application's configuration
      def validate_configuration(configuration)
        raise 'The command must be upload or download' unless ['upload', 'download'].include?(configuration[:command])
        # The library addresses every discovered node and batches on its
        # own, so a target limit would leave nodes out without a word and a
        # batch size would do nothing.
        if options[:mcollective_limit_targets] || options[:batch_size]
          raise 'The --one, --limit-nodes and --batch options are not supported, the library addresses every node it is given and batches on its own'
        end

        [:rpc_timeout, :message_data_size, :upload_batch_size].each do |name|
          value = configuration[name]
          raise "The --#{name.to_s.tr('_', '-')} option must be above zero" if value && !value.positive?
        end

        if configuration[:command] == 'upload'
          raise "#{configuration[:source]} does not exist" unless File.exist?(configuration[:source])
        else
          raise "#{configuration[:destination]} is not a directory" unless File.directory?(configuration[:destination])
        end
      end

      def main
        identities = rpcclient(Util::FileTransfer::Rpc::AGENT).discover
        if identities.empty?
          puts 'No nodes matched the filter'
          exit 1
        end

        client = Util::FileTransfer::Client.new(options, logger: TerminalLogger.new,
          **configuration.slice(:rpc_timeout, :message_data_size, :upload_batch_size).compact)
        outcomes = transfer(client, identities.sort)
        outcomes.each_value do |outcome|
          puts "#{outcome.identity}: #{outcome.success? ? outcome.path : outcome.message}"
        end
        failed = outcomes.values.count { |outcome| !outcome.success? }
        puts
        puts "#{outcomes.length} #{outcomes.length == 1 ? 'node' : 'nodes'}, #{failed} failed"
        # The exit codes of mco commands, 0 when every node succeeded, 2 when
        # any failed, 3 when no node responded, and 1 when none matched,
        # which the discovery check above gives, or when the command could
        # not run, which mco answers itself for an exception.
        exit 0 if failed.zero?
        exit 3 if outcomes.values.all? { |outcome| outcome.kind == :no_response }

        exit 2
      end

      # A download turns each node name into a local directory, so a name
      # that is not one plain component fails its node before any path is built.
      #
      # @param client [Util::FileTransfer::Client]
      # @param identities [Array<String>] The discovered nodes
      # @return [Hash{String => Util::FileTransfer::Outcome}]
      def transfer(client, identities)
        return client.upload(configuration[:source], configuration[:destination], identities) if configuration[:command] == 'upload'

        named, unnamed = identities.partition { |identity| Util::FileTransfer::LocalPath.plain_name?(identity) }
        refused = Util::FileTransfer::Outcome.failures(unnamed, :transfer_failed) do |identity|
          "The node name #{identity.inspect} cannot be a directory under #{configuration[:destination]}"
        end
        destination_dirs = named.to_h { |identity| [identity, File.join(configuration[:destination], identity)] }
        client.download(configuration[:source], destination_dirs).merge(refused)
      end
    end
  end
end
