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

  # request_body replaces the generated request file with the given text.
  # The settings path the server names points at nothing, since the agent
  # reads no settings.
  def run_agent(action, data, protocol: RPC_PROTOCOL, request_body: nil)
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
        'CHORIA_EXTERNAL_CONFIG' => File.join(dir, 'plugin.d', 'file_transfer'),
        'CHORIA_EXTERNAL_FACTS' => facts_path,
        'PATH' => ENV.fetch('PATH', ''),
      }
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '--disable-gems', AGENT, request_path, reply_path,
        RPC_PROTOCOL, unsetenv_others: true, chdir: Dir.tmpdir)
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

  # The temporary files the agent left in a directory.
  def temp_files(dir)
    Dir.children(dir).grep(/\A\.file_transfer-/)
  end

  def mode_of(path)
    format('%04o', File.lstat(path).mode & 0o7777)
  end
end
