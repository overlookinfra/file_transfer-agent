# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer protocol' do
  include_context 'with an agent root'

  describe 'activation' do
    it 'answers an activation request with activate true even though argv names the rpc protocol' do
      reply = run_agent('stat', { 'path' => root }, protocol: ACTIVATION_PROTOCOL)

      expect(reply.raw).to eq('activate' => true)
      expect(reply.exitstatus).to eq(0)
      expect(reply.stderr).to be_empty
    end
  end

  describe 'the reply for a request that fails' do
    it 'exits 0 and writes a reply containing all 3 protocol keys' do
      reply = run_agent('put', { 'destination' => File.join(root, 'missing', 'file.bin'), 'token' => token, 'offset' => 0, 'data' => '' })

      expect(reply.exitstatus).to eq(0)
      expect(reply.raw.keys).to contain_exactly('statuscode', 'statusmsg', 'data')
      expect(reply.statuscode).to eq(1)
      expect(reply.data).to be_empty
    end

    it 'answers an unknown action with the UnknownAction status' do
      reply = run_agent('delete', { 'path' => File.join(root, 'file.bin') })

      expect(reply.statuscode).to eq(2)
      expect(reply.statusmsg).to include('delete')
      expect(reply.data).to be_empty
    end

    it 'answers an action named like a method with the UnknownAction status and still writes the reply' do
      reply = run_agent('exit', {})

      expect(reply.statuscode).to eq(2)
      expect(reply.statusmsg).to include('exit')
      expect(reply.exitstatus).to eq(0)
    end

    it 'reports a request file that is not JSON as UnknownError with the error and its backtrace on stderr' do
      reply = run_agent('get', {}, request_body: 'this is not a request')

      expect(reply.exitstatus).to eq(0)
      expect(reply.statuscode).to eq(5)
      expect(reply.statusmsg).to start_with('JSON::ParserError:')
      expect(reply.data).to eq({})
      expect(reply.stderr).to start_with('The file_transfer agent raised JSON::ParserError:')
      expect(reply.stderr.lines.length).to be > 1
      expect(reply.stderr.lines[1]).to include('.rb:')
    end

    it 'reports an action that raises as UnknownError, naming the action and the error on stderr with its backtrace' do
      reply = run_agent('get', { 'path' => root, 'offset' => 'x', 'max_bytes' => 5 })

      expect(reply.statuscode).to eq(5)
      expect(reply.statusmsg).to start_with('NoMethodError:')
      expect(reply.data).to eq({})
      expect(reply.stderr).to start_with('The file_transfer get action raised NoMethodError:')
      expect(reply.stderr.lines.length).to be > 1
    end
  end

  describe 'the request data' do
    it 'ignores the process_results key the client adds' do
      reply = run_agent('stat', { 'path' => root, 'process_results' => true })

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to include('exists' => true, 'type' => 'directory')
    end

    # The runner starts the agent without a locale, as the server does.
    it 'reads a path with letters outside ASCII' do
      accented = File.join(root, 'café.txt')
      File.write(accented, 'hello')

      reply = run_agent('stat', { 'path' => accented })

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to include('exists' => true, 'type' => 'file', 'size' => 5)
    end

    it 'writes a file whose destination has letters outside ASCII' do
      delivered = File.join(root, 'café délivré.txt')

      reply = run_agent('put', { 'destination' => delivered, 'token' => token, 'offset' => 0, 'data' => chunk('hello'),
                                 'final' => true, 'sha256' => sha256('hello') })

      expect(reply.statuscode).to eq(0)
      expect(File.binread(delivered)).to eq('hello')
      expect(Dir.children(root)).to eq(['café délivré.txt'])
    end
  end

  describe 'the process output' do
    # The server logs stdout at INFO and stderr at ERROR, so a request that
    # succeeds writes nothing to either.
    it 'stays quiet for a successful put, stat, get, and abort' do
      source = File.join(root, 'source.bin')
      File.write(source, 'hello')
      replies = [
        run_agent('put', { 'destination' => File.join(root, 'delivered.bin'), 'token' => token, 'offset' => 0, 'data' => chunk('hello'),
                           'final' => true, 'sha256' => sha256('hello') }),
        run_agent('stat', { 'path' => source }),
        run_agent('get', { 'path' => source, 'offset' => 0, 'max_bytes' => 5 }),
        run_agent('abort', { 'destination' => File.join(root, 'delivered.bin'), 'token' => token }),
      ]

      expect(replies.map(&:statuscode)).to eq([0, 0, 0, 0])
      expect(replies.map(&:stdout)).to all(be_empty)
      expect(replies.map(&:stderr)).to all(be_empty)
    end
  end

  describe 'the temporary file name' do
    it 'has the same prefix in the agent and in the library, which names it in warnings and uses it for its own files' do
      load AGENT unless defined?(FileTransfer::Agent)

      expect(FileTransfer::TEMP_PREFIX).to eq(MCollective::Util::FileTransfer::TEMP_PREFIX)
    end
  end
end
