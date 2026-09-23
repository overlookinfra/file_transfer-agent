# frozen_string_literal: true

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
        arguments: ['--chunk-size BYTES'],
        description: 'Upper bound on the bytes of file content per request, 524288 by default. The chunk sent is the smaller of ' \
                     'this and what the broker message size limit leaves for content once base64 and the request envelope ' \
                     'are accounted for, about 38 percent of that limit',
        type: Integer

      option :download_group_size,
        arguments: ['--download-group-size NODES'],
        description: 'How many nodes a download fetches from at once, 32 by default',
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
        identities = rpcclient(Util::FileTransfer::AGENT).discover
        if identities.empty?
          puts 'No nodes matched the filter'
          exit 1
        end

        outcomes = transfer(Util::FileTransfer::Client.new(**client_settings), identities.sort)
        report(outcomes)
        exit(outcomes.values.all?(&:success?) ? 0 : 2)
      end

      # The library defaults stand for the sizes the command line left out.
      def client_settings
        { connection: Util::FileTransfer::Connection.new(options), rpc_timeout: options[:timeout], cleanup: !configuration[:keep_session],
          **configuration.slice(:chunk_size, :download_group_size).compact }
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
