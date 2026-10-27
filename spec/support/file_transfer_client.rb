# frozen_string_literal: true

require 'fileutils'
require 'mcollective'
require 'mcollective/connector/nats'
require 'tmpdir'
require File.expand_path('../../files/mcollective/util/file_transfer', __dir__)

# Stands in for the NATS wrapper, the one object every request is
# published through, which the publish guard prepends onto.
class FakeNatsWrapper
  attr_reader :published

  def initialize
    @published = []
  end

  def publish(_destination, payload, _reply = nil)
    @published << payload.bytesize
  end
end

# Stands in for MCollective::RPC::Client. An action does whatever the spec
# defined for it with on, called with the arguments, the identities the
# client was last pointed at, and the block the library passed, if any.
# Every call is recorded with its action, arguments, identities and the
# timeout the connection set on the client.
class FakeRpcClient
  attr_reader :identities, :calls
  attr_accessor :batch_size, :batch_sleep_time, :timeout, :progress

  def initialize
    @actions = {}
    @identities = []
    @calls = []
  end

  def on(action, &handler)
    @actions[action] = handler
  end

  # A connection builds a fresh client per call, so the batch settings
  # of the previous call are not kept.
  def discover(nodes:)
    @identities = nodes.dup
    @batch_size = nil
    @batch_sleep_time = nil
  end

  # Every request is checked against the shipped DDL the way that the gem's
  # client checks it before sending, so a request that the DDL refuses
  # fails here as it would on the wire.
  def method_missing(action, *args, &block)
    handler = @actions[action]
    return super unless handler

    arguments = args.first || {}
    RubyDDL.load(MCollective::Util::FileTransfer::Rpc::AGENT).validate_rpc_request(action.to_s, arguments)
    @calls << [action, arguments, @identities.dup, @timeout]
    handler.call(arguments, @identities.dup, &block)
  end

  def respond_to_missing?(action, include_private = false)
    @actions.key?(action) || super
  end
end

# Records the lines the library logged, per level.
class FakeLogger
  attr_reader :debugs, :infos, :warnings, :errors

  def initialize
    @debugs = []
    @infos = []
    @warnings = []
    @errors = []
  end

  def debug(message)
    @debugs << message
  end

  def info(message)
    @infos << message
  end

  def warn(message)
    @warnings << message
  end

  def error(message)
    @errors << message
  end
end

module FileTransferClientHelpers
  # A result for the action the fake is handling, so the gem's Result moves
  # the outputs under their symbol keys by the real DDL, as in production.
  def rpc_result(sender, data = {}, statuscode: 0, statusmsg: 'OK')
    MCollective::RPC::Result.new('file_transfer', rpc.calls.last.first.to_s, sender: sender, statuscode: statuscode, statusmsg: statusmsg, data: data)
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

  # The size of a sent request in the fake, twice its content and a
  # little more, standing in for the envelope and the 2 base64 passes
  # around it, and more in a context that says a chunk is over the limit.
  def wire_size(args)
    (decoded(args).bytesize * 2) + 300
  end

  # put publishes through the fake wrapper, so the guard sees the size of
  # the request, then answers for every addressed identity. An upload
  # that fails a node sends abort, which is recorded in abort_calls and
  # answers removed true.
  def stub_put
    rpc.on(:put) do |args, names|
      put_calls << args.merge(identities: names, batch_size: rpc.batch_size)
      wrapper.publish('mcollective.node.x', 'x' * wire_size(args))
      block_given? ? yield(args, names) : results_for(names)
    end
    rpc.on(:abort) do |args, names|
      abort_calls << args.merge(identities: names)
      results_for(names, { removed: true })
    end
  end

  def stub_stat(&block)
    rpc.on(:stat, &block)
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
end

RSpec.shared_context 'with a file transfer client' do
  include FileTransferClientHelpers

  let(:wrapper) { FakeNatsWrapper.new }
  let(:rpc) { FakeRpcClient.new }
  let(:log) { FakeLogger.new }
  let(:message_data_size) { 16 }
  # Above the agent's DDL timeout, so the wait the examples assert is the
  # caller's. The DDL winning over a smaller value is in rpc_spec, and the
  # library's own default in client_spec.
  let(:rpc_timeout) { 200 }
  let(:client_options) { {} }
  let(:client) do
    MCollective::Util::FileTransfer::Client.new({}, logger: log, rpc_timeout: rpc_timeout, message_data_size: message_data_size, **client_options)
  end
  let(:node1) { 'node1.example.com' }
  let(:node2) { 'node2.example.com' }
  let(:nodes) { [node1, node2] }
  let(:put_calls) { [] }
  let(:abort_calls) { [] }
  let(:workdir) { Dir.mktmpdir('file_transfer-client') }

  # The shipped DDL is loaded through the MCollective config once per
  # process, so the library reads the real timeout and the gem converts
  # every result by the real action interface. The client builds a real
  # connection, every RPC client that connection builds is the fake one,
  # and the connector plugin returns the fake wrapper, which the guard is
  # prepended onto.
  before do
    RubyDDL.load(MCollective::Util::FileTransfer::Rpc::AGENT)
    allow(MCollective::RPC::Client).to receive(:new).and_return(rpc)
    allow(MCollective::PluginManager).to receive(:[]).with('connector_plugin').and_return(instance_double(MCollective::Connector::Nats, connection: wrapper))
  end

  after { FileUtils.remove_entry_secure(workdir) }
end
