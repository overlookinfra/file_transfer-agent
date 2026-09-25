# frozen_string_literal: true

require 'fileutils'
require 'mcollective'
require 'tmpdir'
require File.expand_path('../../files/mcollective/util/file_transfer', __dir__)

# Stands in for the NATS wrapper: the publish guard prepends onto it and
# the broker limit comes from its client's server info.
class FakeNatsWrapper
  attr_reader :published

  def initialize(max_payload)
    @client = Struct.new(:server_info).new({ max_payload: max_payload })
    @published = []
  end

  def publish(_destination, payload, _reply = nil)
    @published << payload.bytesize
  end
end

# Stands in for MCollective::RPC::Client. An action does whatever the spec
# defined for it with on, called with the arguments, the identities the
# client was last pointed at, and the block the library passed, if any.
class FakeRpcClient
  attr_reader :identities, :calls
  attr_accessor :batch_size, :batch_sleep_time

  def initialize
    @actions = {}
    @identities = []
    @calls = []
  end

  def on(action, &handler)
    @actions[action] = handler
  end

  # A connection builds a fresh client per call, so the batch settings
  # of the previous call do not carry over.
  def discover(nodes:)
    @identities = nodes.dup
    @batch_size = nil
    @batch_sleep_time = nil
  end

  def progress=(_value)
    nil
  end

  def method_missing(action, *args, &)
    handler = @actions[action]
    return super unless handler

    arguments = args.first || {}
    @calls << [action, arguments, @identities.dup]
    handler.call(arguments, @identities.dup, &)
  end

  def respond_to_missing?(action, include_private = false)
    @actions.key?(action) || super
  end
end

# The real connection with its client building replaced. Every call is
# recorded and yields the one fake RPC client, pointed at the identities
# of that call, and the wrapper is the fake one, so the guard and the
# limit read are the real code over it.
class FakeConnection < MCollective::Util::FileTransfer::Connection
  attr_reader :client, :calls

  def initialize(wrapper)
    super({})
    @client = FakeRpcClient.new
    @wrapper = wrapper
    @calls = []
  end

  def with_client(agent, identities, timeout:, publish_timeout:)
    @calls << { agent: agent, identities: identities.dup, timeout: timeout, publish_timeout: publish_timeout }
    @client.discover(nodes: identities)
    yield(@client)
  end

  private

  def nats_wrapper
    @wrapper
  end
end

# Records the lines the library logged.
class FakeLogger
  attr_reader :debugs, :warnings, :once

  def initialize
    @debugs = []
    @warnings = []
    @once = []
  end

  def debug(message)
    @debugs << message
  end

  def warn(message)
    @warnings << message
  end

  def warn_once(id, message)
    @once << [id, message]
  end

  def once_ids
    @once.map(&:first)
  end

  def once_messages
    @once.map(&:last)
  end
end

module FileTransferClientHelpers
  def rpc_result(sender, data = {}, statuscode: 0, statusmsg: 'OK')
    MCollective::RPC::Result.new('file_transfer', 'test', sender: sender, statuscode: statuscode, statusmsg: statusmsg, data: data)
  end

  def results_for(names, data = {}, statuscode: 0, statusmsg: 'OK')
    names.map { |name| rpc_result(name, data, statuscode: statuscode, statusmsg: statusmsg) }
  end

  # Chunk data as the library sends it and the agent answers it.
  def encoded(bytes)
    [bytes].pack('m0')
  end

  def decoded(args)
    args[:data].unpack1('m0')
  end

  # What a sent request weighs in the fake, twice its content and a
  # little more, standing in for the envelope and the two base64 passes
  # around it, and more in a context that says a chunk is over the limit.
  def wire_size(args)
    (decoded(args).bytesize * 2) + 300
  end

  # put publishes through the fake wrapper, so the guard sees what the
  # request weighs, then answers for every addressed identity.
  def stub_put
    rpc.on(:put) do |args, names|
      put_calls << args.merge(identities: names, batch_size: rpc.batch_size)
      wrapper.publish('mcollective.node.x', 'x' * wire_size(args))
      block_given? ? yield(args, names) : results_for(names)
    end
  end

  def chunks
    put_calls
  end

  def stub_session
    rpc.on(:mktemp) { |args, names| results_for(names, { path: "/tmp/file_transfer-#{args[:session]}" }) }
    rpc.on(:cleanup) { |_args, names| results_for(names, { removed: true }) }
  end

  def stub_stat(&)
    rpc.on(:stat, &)
  end

  def stub_mkdir
    rpc.on(:mkdir) { |_args, names| results_for(names) }
  end

  def local_file(name, content, mode: 0o644)
    path = File.join(workdir, name)
    File.binwrite(path, content)
    File.chmod(mode, path)
    path
  end

  # The calls that invoked an action, in order.
  def action_calls
    connection.calls
  end
end

RSpec.shared_context 'with a file transfer client' do
  include FileTransferClientHelpers

  let(:max_payload) { 1_048_576 }
  let(:wrapper) { FakeNatsWrapper.new(max_payload) }
  let(:connection) { FakeConnection.new(wrapper) }
  let(:rpc) { connection.client }
  let(:log) { FakeLogger.new }
  let(:chunk_size) { 16 }
  let(:client_options) { {} }
  let(:client) do
    MCollective::Util::FileTransfer::Client.new(connection: connection, logger: log, chunk_size: chunk_size, **client_options)
  end
  let(:node1) { 'node1.example.com' }
  let(:node2) { 'node2.example.com' }
  let(:nodes) { [node1, node2] }
  let(:put_calls) { [] }
  let(:workdir) { Dir.mktmpdir('file_transfer-client') }

  # The agent's DDL answers a 120 second timeout as the shipped one does.
  # RPC results look their action up in the same DDL, and find no interface.
  before do
    allow(MCollective::DDL).to receive(:new).with(MCollective::Util::FileTransfer::Rpc::AGENT)
                                            .and_return(instance_double(MCollective::DDL::AgentDDL, meta: { timeout: 120 }, action_interface: {}))
  end

  after { FileUtils.remove_entry_secure(workdir) }
end
