# frozen_string_literal: true

require 'spec_helper'

# The chunk writing half of put. Verification, the mode and the rename
# into place are in put_final_spec.rb.
RSpec.describe 'the file_transfer agent put action' do
  include_context 'with an agent root'

  # The first chunk of hello, with any key overridden.
  def chunk_request(**extra)
    { destination: destination, token: token, offset: 0, data: chunk('hello') }.merge(extra)
  end

  describe 'the first chunk' do
    it 'creates the temporary file beside the destination with mode 0600 and answers the bytes written and the new size' do
      reply = run_agent('put', chunk_request)

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => 5, 'size' => 5, 'sha256' => nil)
      expect(File.binread(temp_file)).to eq('hello')
      expect(mode_of(temp_file)).to eq('0600')
      expect(File.exist?(destination)).to be(false)
    end

    it 'creates an empty file from empty data' do
      reply = run_agent('put', chunk_request(data: chunk('')))

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => 0, 'size' => 0, 'sha256' => nil)
      expect(File.binread(temp_file)).to eq('')
      expect(mode_of(temp_file)).to eq('0600')
    end

    it 'refuses a temporary name that is already taken and leaves that file alone' do
      run_agent('put', chunk_request(data: chunk('first attempt, longer')))

      reply = run_agent('put', chunk_request)

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('File exists')
      expect(File.binread(temp_file)).to eq('first attempt, longer')
    end

    it 'answers Aborted and creates nothing when the directory of the destination does not exist' do
      missing = File.join(root, 'no-such-dir', 'file.bin')

      reply = run_agent('put', chunk_request(destination: missing))

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('Errno::ENOENT', File.dirname(missing))
      expect(Dir.children(root)).to be_empty
    end
  end

  describe 'a later chunk' do
    it 'writes the chunk in place at the offset' do
      run_agent('put', chunk_request)

      reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => 6, 'size' => 11, 'sha256' => nil)
      expect(File.binread(temp_file)).to eq('hello world')
    end

    it 'rewrites the same bytes when the same chunk is sent again at the same offset' do
      run_agent('put', chunk_request)
      run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

      reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => 6, 'size' => 11, 'sha256' => nil)
      expect(File.binread(temp_file)).to eq('hello world')
    end

    it 'removes the file and reports its size when the offset is past the end of it' do
      run_agent('put', chunk_request)

      reply = run_agent('put', chunk_request(offset: 10, data: chunk('gap!')))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to match(/is 5 bytes.*offset 10/)
      expect(Dir.children(root)).to be_empty
    end

    it 'reports a lost earlier chunk when the file does not exist yet' do
      reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('an earlier chunk was lost')
      expect(Dir.children(root)).to be_empty
    end

    it 'refuses a symbolic link at the temporary name and writes nothing through it' do
      target = File.join(root, 'outside.bin')
      File.write(target, 'hello')
      File.symlink(target, temp_file)

      reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

      expect(reply.statuscode).to eq(1)
      expect(File.binread(target)).to eq('hello')
      expect(File.symlink?(temp_file)).to be(true)
    end
  end

  describe 'the chunk data' do
    it 'rejects data that is not base64 and creates nothing' do
      reply = run_agent('put', chunk_request(data: 'not base64!'))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('The data is not valid base64')
      expect(Dir.children(root)).to be_empty
    end

    it 'rejects base64 containing a newline and creates nothing' do
      reply = run_agent('put', chunk_request(data: "#{chunk('hello')}\n"))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('The data is not valid base64')
      expect(Dir.children(root)).to be_empty
    end
  end

  describe 'invalid input' do
    it 'rejects a negative offset and creates nothing' do
      reply = run_agent('put', chunk_request(offset: -1))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('The offset input must be at least 0')
      expect(Dir.children(root)).to be_empty
    end
  end

  describe 'the reply of a non-final chunk' do
    it 'neither renames nor changes the mode when the mode arrives before the final chunk' do
      reply = run_agent('put', chunk_request(mode: '0755'))

      expect(reply.statuscode).to eq(0)
      expect(File.exist?(destination)).to be(false)
      expect(File.binread(temp_file)).to eq('hello')
      expect(mode_of(temp_file)).to eq('0600')
    end

    it 'accepts a sha256 without verifying it and answers a null digest' do
      reply = run_agent('put', chunk_request(sha256: sha256('other content')))

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => 5, 'size' => 5, 'sha256' => nil)
      expect(File.binread(temp_file)).to eq('hello')
    end
  end
end
