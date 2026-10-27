# frozen_string_literal: true

require 'fileutils'
require 'mcollective'
require_relative '../util/file_transfer'

module MCollective
  class Application
    # The mco file_transfer command, a plain client of the agent through the
    # library the module ships with it.
    class File_transfer < Application # rubocop:disable Naming/ClassAndModuleCamelCase
      # The library's warnings and errors, such as an entry skipped in a tree,
      # a temporary file left on a node or a call that raised, go to the
      # MCollective log and, since they're for the person at the terminal, to
      # stderr beside the per node lines as well. Debug and info lines go to
      # the log alone. A client config may send the log nowhere.
      class TerminalLogger
        def debug(message)
          Log.debug(message)
        end

        def info(message)
          Log.info(message)
        end

        # Kernel#warn prints nothing under -W0, and these lines are not
        # Ruby warnings.
        def warn(message)
          Log.warn(message)
          $stderr.puts(message) # rubocop:disable Style/StderrPuts
        end

        def error(message)
          Log.error(message)
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
        description: 'Data per request in kibibytes, the file content of a chunk and the biggest size a directory listing may ' \
                     'be. Default is 512, half the Choria broker message size limit of 1 MiB. A request over the limit fails ' \
                     'its node with payload_too_large, and a reply over it never arrives, so the node shows as no_response.',
        type: Integer

      option :upload_batch_size,
        arguments: ['--upload-batch-size NODES'],
        description: 'How many nodes one chunk request is published to at once. Default is 256, which keeps one batch of ' \
                     'requests under 256 MiB of memory on this host at the broker message size limit.',
        type: Integer

      option :rpc_timeout,
        arguments: ['--rpc-timeout SECONDS'],
        description: 'Seconds to wait for every node\'s reply to one call, and to publish one call to every node. Default is ' \
                     'the library\'s 300 seconds. The wait is never shorter than the agent\'s DDL timeout, 120 seconds. ' \
                     'mco\'s own --timeout has no effect on this command, and --discovery-timeout bounds the discovery of ' \
                     'the nodes only.',
        type: Integer

      # Takes the command and its 2 paths from the remaining arguments.
      #
      # @param configuration [Hash] The application's configuration
      def post_option_parser(configuration)
        raise 'Please specify upload or download, a source, and a destination' unless ARGV.length == 3

        configuration[:command], configuration[:source], configuration[:destination] = ARGV.shift(3)
      end

      # @param configuration [Hash] The application's configuration
      def validate_configuration(configuration)
        raise 'The command must be upload or download' unless ['upload', 'download'].include?(configuration[:command])
        # The library addresses every discovered node and batches on its
        # own, so a target limit would leave nodes out and a batch size
        # would do nothing.
        if options[:mcollective_limit_targets] || options[:batch_size]
          raise 'The --one, --limit-nodes and --batch options are not supported. The library addresses every node it is given and batches on its own.'
        end

        if configuration[:command] == 'upload'
          raise "#{configuration[:source]} does not exist" unless File.exist?(configuration[:source])
        elsif File.exist?(configuration[:destination]) && !File.directory?(configuration[:destination])
          raise "#{configuration[:destination]} is not a directory"
        end
      end

      def main
        # Built before discovery, so that a setting the client refuses stops
        # the command before any node is contacted.
        client = Util::FileTransfer::Client.new(options, logger: TerminalLogger.new,
          **configuration.slice(:rpc_timeout, :message_data_size, :upload_batch_size).compact)
        identities = rpcclient(Util::FileTransfer::Rpc::AGENT).discover
        if identities.empty?
          puts 'No nodes matched the filter'
          exit 1
        end

        # The gem's request loop rescues Interrupt and goes on, so a Ctrl-C
        # would only cut one call short. A SignalException passes that rescue
        # and the library's, so the transfer stops, an upload sending abort to
        # its unfinished nodes and a download removing its temporary files.
        previous = Signal.trap('INT') { raise SignalException, 'INT' }
        begin
          outcomes = transfer(client, identities.sort)
        ensure
          Signal.trap('INT', previous)
        end
        outcomes.each_value do |outcome|
          puts "#{outcome.identity}: #{outcome.success? ? outcome.path : outcome.error_message}"
        end
        failed = outcomes.values.count { |outcome| !outcome.success? }
        puts
        puts "#{outcomes.length} #{outcomes.length == 1 ? 'node' : 'nodes'}, #{failed} failed"
        # The exit codes of mco commands, 0 when every node succeeded, 2 when
        # any failed, 3 when no node responded, and 1 when none matched,
        # which the discovery check above gives, or when the command could
        # not run, which mco answers itself for an exception.
        exit 0 if failed.zero?
        exit 3 if outcomes.values.all? { |outcome| outcome.error_kind == :no_response }

        exit 2
      end

      # Each node name becomes a directory under the destination, so a node
      # whose name isn't one plain component fails before any path is built.
      #
      # @param client [Util::FileTransfer::Client]
      # @param identities [Array<String>] The discovered nodes
      # @return [Hash{String => Util::FileTransfer::Outcome}]
      def transfer(client, identities)
        return client.upload(configuration[:source], configuration[:destination], identities) if configuration[:command] == 'upload'

        FileUtils.mkdir_p(configuration[:destination])
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
