# frozen_string_literal: true

require 'spec_helper'
require 'socket'

RSpec.describe 'file_transfer put final chunk' do
  include_context 'with an agent root'

  let(:content) { 'the quick brown fox jumps over the lazy dog' }
  let(:destination_path) { File.join(root, 'delivered.bin') }

  # One final chunk containing the whole of content at offset 0, with the
  # digest the agent should compute for it and the destination it renames to.
  def final_chunk(**extra)
    { destination: destination_path, token: token, offset: 0, data: chunk(content), final: true, sha256: sha256(content) }.merge(extra)
  end

  describe 'a final chunk that verifies' do
    it 'answers the digest of the whole file' do
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(0)
      expect(reply.statusmsg).to eq('OK')
      expect(reply.data).to eq('bytes' => content.bytesize, 'size' => content.bytesize, 'sha256' => sha256(content))
    end

    it 'delivers an empty file from one final chunk with empty data' do
      reply = run_agent('put', final_chunk(data: chunk(''), sha256: sha256('')))

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => 0, 'size' => 0, 'sha256' => sha256(''))
      expect(File.binread(destination_path)).to eq('')
      expect(mode_of(destination_path)).to eq('0600')
    end

    it 'verifies a multi-chunk file over the whole content' do
      head = 'the first half of the payload, '
      tail = 'and the second half of it'
      whole = head + tail
      run_agent('put', { destination: destination_path, token: token, offset: 0, data: chunk(head) })
      reply = run_agent('put', { destination: destination_path, token: token, offset: head.bytesize, data: chunk(tail),
                                 final: true, sha256: sha256(whole) })

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => tail.bytesize, 'size' => whole.bytesize, 'sha256' => sha256(whole))
      expect(File.binread(destination_path)).to eq(whole)
    end
  end

  describe 'a final chunk missing its digest or containing the wrong one' do
    it 'answers MissingData when final is set without a sha256 and writes nothing' do
      reply = run_agent('put', final_chunk.except(:sha256))

      expect(reply.statuscode).to eq(3)
      expect(reply.statusmsg).to include('sha256')
      expect(Dir.children(root)).to be_empty
    end

    it 'answers Aborted with both digests when the content does not match the sha256, removes the file and renames nothing' do
      reply = run_agent('put', final_chunk(sha256: 'a' * 64))

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('a' * 64).and include(sha256(content))
      expect(reply.data['sha256']).to eq(sha256(content))
      expect(Dir.children(root)).to be_empty
    end

    it 'leaves a file already at the destination untouched when the content does not match the sha256' do
      File.write(destination_path, 'the good copy')

      reply = run_agent('put', final_chunk(sha256: 'a' * 64))

      expect(reply.statuscode).to eq(1)
      expect(File.binread(destination_path)).to eq('the good copy')
      expect(Dir.children(root)).to eq(['delivered.bin'])
    end
  end

  describe 'renaming a verified file into place' do
    it 'renames the temporary file onto the destination with mode 0600 when no mode is given' do
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(0)
      expect(reply.data['sha256']).to eq(sha256(content))
      expect(File.binread(destination_path)).to eq(content)
      expect(mode_of(destination_path)).to eq('0600')
      expect(Dir.children(root)).to eq(['delivered.bin'])
    end

    it 'applies the requested mode to the destination' do
      reply = run_agent('put', final_chunk(mode: '0640'))

      expect(reply.statuscode).to eq(0)
      expect(mode_of(destination_path)).to eq('0640')
    end

    it 'applies setuid, setgid, and sticky bits when the mode asks for them, as an SSH upload preserves them' do
      reply = run_agent('put', final_chunk(mode: '6755'))

      expect(reply.statuscode).to eq(0)
      expect(mode_of(destination_path)).to eq('6755')
    end

    it 'replaces an existing regular file at the destination' do
      File.write(destination_path, 'the content that was there before')
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(0)
      expect(File.binread(destination_path)).to eq(content)
    end

    it 'replaces a symbolic link at the destination and leaves the link target alone' do
      link_target = File.join(root, 'link-target.bin')
      File.write(link_target, 'the link target')
      File.symlink(link_target, destination_path)
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(0)
      expect(File.lstat(destination_path).symlink?).to be(false)
      expect(File.binread(destination_path)).to eq(content)
      expect(File.binread(link_target)).to eq('the link target')
    end

    it 'refuses a destination that is a named pipe, before writing anything' do
      File.mkfifo(destination_path, 0o600)
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include("#{destination_path} is a named pipe, so the file is not put there")
      expect(File.ftype(destination_path)).to eq('fifo')
      expect(temp_files(root)).to be_empty
    end

    it 'refuses a destination that is a socket, naming it a socket' do
      UNIXServer.new(destination_path).close
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include("#{destination_path} is a socket, so the file is not put there")
      expect(File.ftype(destination_path)).to eq('socket')
      expect(temp_files(root)).to be_empty
    end

    it 'answers Aborted and leaves nothing beside the destination when it is a directory' do
      Dir.mkdir(destination_path)
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(destination_path)
      expect(reply.stderr).to eq('')
      expect(File.directory?(destination_path)).to be(true)
      expect(Dir.children(root)).to eq(['delivered.bin'])
    end

    it 'answers InvalidData for a relative destination' do
      reply = run_agent('put', final_chunk(destination: 'delivered.bin'))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('destination')
      expect(Dir.children(root)).to be_empty
    end

    it 'refuses a destination that ends in a separator, rather than making a file of that name' do
      named = File.join(root, 'conf.d')
      reply = run_agent('put', final_chunk(destination: "#{named}/"))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('must name a file')
      expect(Dir.children(root)).to be_empty
    end

    it 'renames to the normalized path when the destination contains current and parent references' do
      reply = run_agent('put', final_chunk(destination: File.join(root, 'sub', '..', '.', 'delivered.bin')))

      expect(reply.statuscode).to eq(0)
      expect(File.binread(destination_path)).to eq(content)
      expect(Dir.children(root)).to eq(['delivered.bin'])
    end
  end
end
