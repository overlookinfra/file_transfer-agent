# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'file_transfer put final chunk' do
  include_context 'with an agent root'

  let(:session_name) { 'file.bin' }
  let(:content) { 'the quick brown fox jumps over the lazy dog' }
  let(:session_file) { File.join(session_dir(root, uuid), session_name) }
  let(:target_dir) { Dir.mktmpdir('file_transfer-dest') }
  let(:destination_path) { File.join(target_dir, 'delivered.bin') }

  before { run_agent('mktemp', { session: uuid }) }

  after { FileUtils.remove_entry_secure(target_dir) }

  # One final chunk carrying the whole of content at offset 0, with the
  # digest the agent should compute for it.
  def final_chunk(**extra)
    { session: uuid, name: session_name, offset: 0, data: chunk(content), final: true, sha256: sha256(content) }.merge(extra)
  end

  # The first candidate directory that sits on another filesystem than the
  # session root, or nil when they all share one.
  def other_filesystem
    root_device = File.stat(root).dev
    ['/dev/shm', Dir.tmpdir, '/workspace', '/root'].find do |candidate|
      File.directory?(candidate) && File.stat(candidate).dev != root_device
    rescue SystemCallError
      false
    end
  end

  describe 'a verified file that stays in the session' do
    it 'answers the digest of the whole file' do
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(0)
      expect(reply.statusmsg).to eq('OK')
      expect(reply.data).to eq('bytes' => content.bytesize, 'size' => content.bytesize, 'sha256' => sha256(content))
    end

    it 'keeps the verified file in the session with mode 0600 when no destination or mode is given' do
      reply = run_agent('put', final_chunk)

      expect(reply.statuscode).to eq(0)
      expect(reply.data['sha256']).to eq(sha256(content))
      expect(File.binread(session_file)).to eq(content)
      expect(mode_of(session_file)).to eq('0600')
    end

    it 'delivers an empty file from one final chunk with empty data' do
      reply = run_agent('put', final_chunk(data: chunk(''), sha256: sha256(''), destination: destination_path))

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => 0, 'size' => 0, 'sha256' => sha256(''))
      expect(File.binread(destination_path)).to eq('')
      expect(mode_of(destination_path)).to eq('0600')
    end

    it 'applies a requested mode of 0640 to the verified file' do
      reply = run_agent('put', final_chunk(mode: '0640'))

      expect(reply.statuscode).to eq(0)
      expect(mode_of(session_file)).to eq('0640')
    end

    it 'applies a requested mode of 0755 to the verified file' do
      reply = run_agent('put', final_chunk(mode: '0755'))

      expect(reply.statuscode).to eq(0)
      expect(mode_of(session_file)).to eq('0755')
    end

    it 'verifies a multi-chunk file over the whole content' do
      head = 'the first half of the payload, '
      tail = 'and the second half of it'
      whole = head + tail
      run_agent('put', { session: uuid, name: session_name, offset: 0, data: chunk(head) })
      reply = run_agent('put', { session: uuid, name: session_name, offset: head.bytesize, data: chunk(tail),
                                 final: true, sha256: sha256(whole) })

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('bytes' => tail.bytesize, 'size' => whole.bytesize, 'sha256' => sha256(whole))
      expect(File.binread(session_file)).to eq(whole)
    end
  end

  describe 'a final chunk whose digest is missing or malformed' do
    it 'answers MissingData when final is set without a sha256' do
      reply = run_agent('put', { session: uuid, name: session_name, offset: 0, data: chunk(content), final: true })

      expect(reply.statuscode).to eq(3)
      expect(reply.statusmsg).to include('sha256')
    end

    it 'answers InvalidData for an uppercase sha256' do
      reply = run_agent('put', final_chunk(sha256: sha256(content).upcase))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('sha256')
    end

    it 'answers InvalidData for a sha256 shorter than 64 characters' do
      reply = run_agent('put', final_chunk(sha256: sha256(content)[0, 63]))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('sha256')
    end

    it 'answers Aborted with both digests when the content does not match the sha256 and keeps the file for cleanup' do
      reply = run_agent('put', final_chunk(sha256: 'a' * 64))

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('a' * 64).and include(sha256(content))
      expect(reply.data['sha256']).to eq(sha256(content))
      expect(File.binread(session_file)).to eq(content)
    end
  end

  describe 'delivering a verified file to a destination' do
    it 'renames the verified file onto the destination and removes it from the session' do
      reply = run_agent('put', final_chunk(destination: destination_path))

      expect(reply.statuscode).to eq(0)
      expect(reply.data['sha256']).to eq(sha256(content))
      expect(File.binread(destination_path)).to eq(content)
      expect(File.exist?(session_file)).to be(false)
    end

    it 'applies the requested mode to the destination' do
      reply = run_agent('put', final_chunk(destination: destination_path, mode: '0640'))

      expect(reply.statuscode).to eq(0)
      expect(mode_of(destination_path)).to eq('0640')
    end

    it 'applies setuid, setgid, and sticky bits when the mode asks for them, as an SSH upload preserves them' do
      reply = run_agent('put', final_chunk(destination: destination_path, mode: '6755'))

      expect(reply.statuscode).to eq(0)
      expect(mode_of(destination_path)).to eq('6755')
    end

    it 'refuses a destination inside the temp root before writing anything' do
      inside = File.join(root, 'delivered.bin')
      reply = run_agent('put', final_chunk(destination: inside))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('temporary root')
      expect(File.exist?(inside)).to be(false)
      expect(File.exist?(session_file)).to be(false)
    end

    it 'replaces an existing regular file at the destination' do
      File.write(destination_path, 'the content that was there before')
      reply = run_agent('put', final_chunk(destination: destination_path))

      expect(reply.statuscode).to eq(0)
      expect(File.binread(destination_path)).to eq(content)
    end

    it 'replaces a symbolic link at the destination and leaves the link target alone' do
      link_target = File.join(target_dir, 'link-target.bin')
      File.write(link_target, 'the link target')
      File.symlink(link_target, destination_path)
      reply = run_agent('put', final_chunk(destination: destination_path))

      expect(reply.statuscode).to eq(0)
      expect(File.lstat(destination_path).symlink?).to be(false)
      expect(File.binread(destination_path)).to eq(content)
      expect(File.binread(link_target)).to eq('the link target')
    end

    it 'answers Aborted and keeps the session file when the destination is a directory' do
      Dir.mkdir(destination_path)
      reply = run_agent('put', final_chunk(destination: destination_path))

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(destination_path)
      expect(reply.stderr).to eq('')
      expect(File.directory?(destination_path)).to be(true)
      expect(File.binread(session_file)).to eq(content)
    end

    it 'answers Aborted when the parent of the destination does not exist' do
      missing = File.join(target_dir, 'no-such-dir', 'delivered.bin')
      reply = run_agent('put', final_chunk(destination: missing))

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('Errno::ENOENT', File.dirname(missing))
      expect(Dir.exist?(File.dirname(missing))).to be(false)
    end

    it 'answers InvalidData for a relative destination' do
      reply = run_agent('put', final_chunk(destination: 'delivered.bin'))

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('destination')
      expect(File.exist?(session_file)).to be(false)
    end
  end

  describe 'delivering across a filesystem boundary' do
    let(:far_dir) { Dir.mktmpdir('file_transfer-xdev', other_filesystem) }

    before { skip('needs a directory on a second filesystem') if other_filesystem.nil? }

    after { FileUtils.remove_entry_secure(far_dir) unless other_filesystem.nil? }

    it 'writes the verified file and its mode to a destination on another filesystem' do
      far_path = File.join(far_dir, 'delivered.bin')
      reply = run_agent('put', final_chunk(destination: far_path, mode: '0640'))

      expect(reply.statuscode).to eq(0)
      expect(File.binread(far_path)).to eq(content)
      expect(mode_of(far_path)).to eq('0640')
      expect(File.exist?(session_file)).to be(false)
    end

    it 'leaves no staging file beside a cross-filesystem destination' do
      far_path = File.join(far_dir, 'delivered.bin')
      reply = run_agent('put', final_chunk(destination: far_path))

      expect(reply.statuscode).to eq(0)
      expect(Dir.children(far_dir)).to contain_exactly('delivered.bin')
    end

    it 'delivers a file whose name is as long as the filesystem allows across the boundary' do
      far_path = File.join(far_dir, "#{'n' * 251}.bin")
      reply = run_agent('put', final_chunk(destination: far_path))

      expect(reply.statuscode).to eq(0)
      expect(File.binread(far_path)).to eq(content)
      expect(Dir.children(far_dir).length).to eq(1)
    end
  end

  describe 'normalizing the destination' do
    it 'delivers to the normalized path when the destination holds a current directory component' do
      reply = run_agent('put', final_chunk(destination: File.join(target_dir, '.', 'delivered.bin')))

      expect(reply.statuscode).to eq(0)
      expect(File.binread(destination_path)).to eq(content)
    end

    it 'delivers to the normalized path when the destination holds a parent reference' do
      reply = run_agent('put', final_chunk(destination: File.join(target_dir, 'sub', '..', 'delivered.bin')))

      expect(reply.statuscode).to eq(0)
      expect(File.binread(destination_path)).to eq(content)
      expect(File.exist?(File.join(target_dir, 'sub'))).to be(false)
    end
  end
end
