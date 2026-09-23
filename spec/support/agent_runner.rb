# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'
require 'tmpdir'

# Runs the agent the way the Choria server does: one process per request,
# a request file and a reply file, six environment variables and nothing
# else, and the OS temp dir as the working directory.
module AgentRunner
  # The parsed reply file plus what the process wrote and how it exited.
  # For an activation request the reply has no status fields, only raw.
  Reply = Struct.new(:statuscode, :statusmsg, :data, :raw, :stdout, :stderr, :exitstatus)

  # config is the example's settings file from the shared context unless
  # given. request_body replaces the generated request file with the given
  # text.
  def run_agent(action, data, config: self.config, protocol: RPC_PROTOCOL, request_body: nil)
    Dir.mktmpdir('file_transfer-spec') do |dir|
      request_path = File.join(dir, 'request.json')
      reply_path = File.join(dir, 'reply.json')
      facts_path = File.join(dir, 'facts.json')
      File.write(facts_path, '{}')
      File.write(request_path, request_body || JSON.generate(request(action, data)))
      env = {
        'CHORIA_EXTERNAL_REQUEST' => request_path,
        'CHORIA_EXTERNAL_REPLY' => reply_path,
        'CHORIA_EXTERNAL_PROTOCOL' => protocol,
        'CHORIA_EXTERNAL_CONFIG' => config,
        'CHORIA_EXTERNAL_FACTS' => facts_path,
        'PATH' => ENV.fetch('PATH', ''),
      }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, AGENT, request_path, reply_path, RPC_PROTOCOL,
        unsetenv_others: true, chdir: Dir.tmpdir)
      reply = File.exist?(reply_path) ? JSON.parse(File.read(reply_path)) : {}
      Reply.new(statuscode: reply['statuscode'], statusmsg: reply['statusmsg'], data: reply['data'], raw: reply,
        stdout: stdout, stderr: stderr, exitstatus: status.exitstatus)
    end
  end

  def request(action, data)
    {
      '$schema' => 'https://choria.io/schemas/mcorpc/external/v1/rpc_request.json',
      'protocol' => RPC_PROTOCOL,
      'agent' => 'file_transfer',
      'action' => action,
      'requestid' => SecureRandom.hex(16),
      'senderid' => 'tester.example.net',
      'callerid' => 'choria=tester.mcollective',
      'collective' => 'mcollective',
      'ttl' => 60,
      'msgtime' => Time.now.to_i,
      'data' => data,
    }
  end

  # Writes the settings file where the module would put it and returns the
  # extensionless path the Choria server passes in CHORIA_EXTERNAL_CONFIG.
  def write_config(dir, settings, extension: '.cfg')
    plugin_dir = File.join(dir, 'plugin.d')
    FileUtils.mkdir_p(plugin_dir)
    lines = settings.sort.map { |key, value| "#{key} = #{value}" }
    File.write(File.join(plugin_dir, "file_transfer#{extension}"), lines.join("\n"))
    File.join(plugin_dir, 'file_transfer')
  end

  # Chunk data as put carries it and get answers it.
  def chunk(bytes)
    [bytes].pack('m0')
  end

  def decoded(reply)
    reply.data['data'].unpack1('m0')
  end

  def sha256(bytes)
    Digest::SHA256.hexdigest(bytes)
  end

  def session_dir(root, uuid)
    File.join(root, "file_transfer-#{uuid}")
  end

  def mode_of(path)
    format('%04o', File.lstat(path).mode & 0o7777)
  end
end
