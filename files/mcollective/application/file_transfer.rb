# frozen_string_literal: true

require 'mcollective'
require_relative '../util/file_transfer'

module MCollective
  class Application
    # The mco file_transfer command, a plain client of the agent through the
    # library the module ships with it. MCollective derives the class name
    # from the command name, hence the underscore.
    class File_transfer < Application # rubocop:disable Naming/ClassAndModuleCamelCase
      description 'Move files to and from nodes through the file_transfer agent'

      usage <<~END_OF_USAGE
        mco file_transfer [OPTIONS] [FILTERS] upload SOURCE DESTINATION
        mco file_transfer [OPTIONS] [FILTERS] download SOURCE DIRECTORY

        upload sends a local file or directory tree to DESTINATION on every node.
        download fetches SOURCE from every node into a directory under DIRECTORY
        named after the node, such as DIRECTORY/web1.example.net/app.log.
      END_OF_USAGE

      option :chunk_size,
        arguments: ['--chunk-size KIBIBYTES'],
        description: 'File content per request in kibibytes, 512 by default, which fits the broker message size limit ' \
                     'of 1 MiB. Lower it where the limit is smaller. A request over the limit fails its node with ' \
                     'payload_too_large.',
        type: Integer

      option :upload_batch_size,
        arguments: ['--upload-batch-size NODES'],
        description: 'How many nodes one chunk request is published to at once. Without it, the size is chosen to keep one ' \
                     'batch of requests under 256 MiB of memory on this host at the broker message size limit.',
        type: Integer

      option :download_batch_size,
        arguments: ['--download-batch-size NODES'],
        description: 'How many nodes a download fetches from at once. Without it, the size is chosen to keep one batch of ' \
                     'replies under three quarters of the 64 MiB the broker holds for this host before closing ' \
                     'its connection.',
        type: Integer

      option :keep_session,
        arguments: ['--keep-session'],
        description: 'Leave the session directory on the nodes after an upload',
        type: :bool

      def post_option_parser(configuration)
        raise 'Please specify upload or download, a source, and a destination' unless ARGV.length == 3

        configuration[:command], configuration[:source], configuration[:target] = ARGV.shift(3)
      end

      def validate_configuration(configuration)
        raise 'The command must be upload or download' unless ['upload', 'download'].include?(configuration[:command])

        if configuration[:command] == 'upload'
          raise "#{configuration[:source]} does not exist" unless File.exist?(configuration[:source])
        else
          raise "#{configuration[:target]} is not a directory" unless File.directory?(configuration[:target])
        end
      end

      def main
        identities = rpcclient(Util::FileTransfer::Rpc::AGENT).discover
        if identities.empty?
          puts 'No nodes matched the filter'
          exit 1
        end

        client = Util::FileTransfer::Client.new(
          connection: Util::FileTransfer::Connection.new(options),
          rpc_timeout: options[:timeout],
          cleanup: !configuration[:keep_session],
          **configuration.slice(:chunk_size, :upload_batch_size, :download_batch_size).compact
        )
        outcomes = transfer(client, identities.sort)
        report(outcomes)
        exit(exit_code(outcomes))
      end

      # The codes of mco commands: 0 when every node succeeded, 2 when any
      # failed, 3 when no node responded, and 1 above when none matched, which
      # is already handled by main().
      def exit_code(outcomes)
        return 0 if outcomes.values.all?(&:success?)
        return 3 if outcomes.values.all? { |outcome| outcome.kind == :no_response }

        2
      end

      def transfer(client, identities)
        if configuration[:command] == 'upload'
          client.upload(configuration[:source], configuration[:target], identities)
        else
          client.download(configuration[:source], identities.to_h { |identity| [identity, File.join(configuration[:target], identity)] })
        end
      end

      def report(outcomes)
        outcomes.each_value do |outcome|
          puts "#{outcome.identity}: #{outcome.success? ? outcome.path : outcome.message}"
        end
        failed = outcomes.values.count { |outcome| !outcome.success? }
        puts
        puts "#{outcomes.length} #{outcomes.length == 1 ? 'node' : 'nodes'}, #{failed} failed"
      end
    end
  end
end
