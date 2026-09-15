# frozen_string_literal: true

require 'spec_helper'

# The chunk writing half of put. Verification, mode, and delivery live in
# put_final_spec.rb.
RSpec.describe 'the file_transfer agent put action' do
  include_context 'with an agent root'

  let(:session) { run_agent('mktemp', { session: uuid }).data.fetch('path') }

  # The first chunk of hello into file.bin, with any key overridden.
  def chunk_request(**extra)
    { session: uuid, name: 'file.bin', offset: 0, data: chunk('hello') }.merge(extra)
  end

  describe 'the session directory check' do
    it 'aborts when the session directory does not exist' do
      reply = run_agent('put', chunk_request)

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include("Session #{session_dir(root, uuid)} does not exist")
      expect(Dir.children(root)).to be_empty
    end

    it 'refuses a session directory that is a symbolic link and writes nothing into its target' do
      target = File.join(root, 'planted')
      Dir.mkdir(target, 0o700)
      File.symlink(target, session_dir(root, uuid))

      reply = run_agent('put', chunk_request)

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('is a symbolic link')
      expect(Dir.children(target)).to be_empty
    end

    it 'refuses a session path that is a regular file and leaves it alone' do
      path = session_dir(root, uuid)
      File.write(path, 'not a session')

      reply = run_agent('put', chunk_request)

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('is not a directory')
      expect(File.binread(path)).to eq('not a session')
    end

    it 'refuses a session directory owned by another user' do
      path = session_dir(root, uuid)
      Dir.mkdir(path, 0o700)
      File.chown(65_534, 65_534, path)

      reply = run_agent('put', chunk_request)

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include("is not owned by the agent's user")
      expect(Dir.children(path)).to be_empty
    end

    { 'group bits' => 0o750, 'other bits' => 0o705 }.each do |description, mode|
      it "refuses a session directory with #{description}" do
        path = session_dir(root, uuid)
        Dir.mkdir(path, 0o700)
        File.chmod(mode, path)

        reply = run_agent('put', chunk_request)

        expect(reply.statuscode).to eq(1)
        expect(reply.statusmsg).to include('is accessible to other users')
        expect(Dir.children(path)).to be_empty
      end
    end
  end

  context 'with a session the agent created' do
    let(:file_path) { File.join(session, 'file.bin') }

    before { session }

    describe 'the first chunk' do
      it 'creates the file with mode 0600 and answers the bytes written and the new size' do
        reply = run_agent('put', chunk_request)

        expect(reply.statuscode).to eq(0)
        expect(reply.data).to eq('bytes' => 5, 'size' => 5, 'sha256' => nil)
        expect(File.binread(file_path)).to eq('hello')
        expect(mode_of(file_path)).to eq('0600')
      end

      it 'creates an empty file from empty data' do
        reply = run_agent('put', chunk_request(data: chunk('')))

        expect(reply.statuscode).to eq(0)
        expect(reply.data).to eq('bytes' => 0, 'size' => 0, 'sha256' => nil)
        expect(File.binread(file_path)).to eq('')
        expect(mode_of(file_path)).to eq('0600')
      end

      it 'refuses a name the session already holds a file at and leaves that file alone' do
        run_agent('put', chunk_request(data: chunk('first attempt, longer')))

        reply = run_agent('put', chunk_request)

        expect(reply.statuscode).to eq(1)
        expect(reply.statusmsg).to include('File exists')
        expect(File.binread(file_path)).to eq('first attempt, longer')
      end

      it 'refuses a directory at the same name' do
        Dir.mkdir(file_path)

        reply = run_agent('put', chunk_request)

        expect(reply.statuscode).to eq(1)
        expect(File.directory?(file_path)).to be(true)
      end

      it 'refuses a symbolic link at the same name and writes nothing through it' do
        target = File.join(root, 'outside.bin')
        File.write(target, 'original')
        File.symlink(target, file_path)

        reply = run_agent('put', chunk_request)

        expect(reply.statuscode).to eq(1)
        expect(File.binread(target)).to eq('original')
        expect(File.symlink?(file_path)).to be(true)
      end
    end

    describe 'a name with directories' do
      it 'creates each missing parent inside the session with mode 0700' do
        name = 'modules/mymod/files/run.sh'

        reply = run_agent('put', chunk_request(name: name, data: chunk('run me')))

        expect(reply.statuscode).to eq(0)
        expect(mode_of(File.join(session, 'modules'))).to eq('0700')
        expect(mode_of(File.join(session, 'modules', 'mymod'))).to eq('0700')
        expect(mode_of(File.join(session, 'modules', 'mymod', 'files'))).to eq('0700')
        expect(File.binread(File.join(session, name))).to eq('run me')
        expect(mode_of(File.join(session, name))).to eq('0600')
      end
    end

    describe 'a later chunk' do
      it 'writes the chunk in place at the offset' do
        run_agent('put', chunk_request)

        reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

        expect(reply.statuscode).to eq(0)
        expect(reply.data).to eq('bytes' => 6, 'size' => 11, 'sha256' => nil)
        expect(File.binread(file_path)).to eq('hello world')
      end

      it 'rewrites the same bytes when the same chunk is sent again at the same offset' do
        run_agent('put', chunk_request)
        run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

        reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

        expect(reply.statuscode).to eq(0)
        expect(reply.data).to eq('bytes' => 6, 'size' => 11, 'sha256' => nil)
        expect(File.binread(file_path)).to eq('hello world')
      end

      it 'reports the actual size when the offset is past the end of the file' do
        run_agent('put', chunk_request)

        reply = run_agent('put', chunk_request(offset: 10, data: chunk('gap!')))

        expect(reply.statuscode).to eq(4)
        expect(reply.statusmsg).to match(/file\.bin is 5 bytes.*offset 10/)
        expect(File.binread(file_path)).to eq('hello')
      end

      it 'reports a lost earlier chunk when the file does not exist yet' do
        reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

        expect(reply.statuscode).to eq(4)
        expect(reply.statusmsg).to include('does not exist in the session')
        expect(Dir.children(session)).to be_empty
      end

      it 'refuses a leaf that is a symbolic link and writes nothing through it' do
        target = File.join(root, 'outside.bin')
        File.write(target, 'hello')
        File.symlink(target, file_path)

        reply = run_agent('put', chunk_request(offset: 5, data: chunk(' world')))

        expect(reply.statuscode).to eq(1)
        expect(File.binread(target)).to eq('hello')
      end
    end

    describe 'the chunk data' do
      it 'decodes the chunk and answers its byte count' do
        payload = 'a line of text that repeats. ' * 40

        reply = run_agent('put', chunk_request(data: chunk(payload)))

        expect(reply.statuscode).to eq(0)
        expect(reply.data).to eq('bytes' => payload.bytesize, 'size' => payload.bytesize, 'sha256' => nil)
        expect(File.binread(file_path)).to eq(payload)
      end

      it 'rejects data that is not base64 and creates nothing' do
        reply = run_agent('put', chunk_request(data: 'not base64!'))

        expect(reply.statuscode).to eq(4)
        expect(reply.statusmsg).to include('The data is not valid base64')
        expect(Dir.children(session)).to be_empty
      end

      it 'rejects base64 carrying a newline and creates nothing' do
        reply = run_agent('put', chunk_request(data: "#{chunk('hello')}\n"))

        expect(reply.statuscode).to eq(4)
        expect(reply.statusmsg).to include('The data is not valid base64')
        expect(Dir.children(session)).to be_empty
      end
    end

    describe 'invalid input' do
      it 'rejects a negative offset and creates nothing' do
        reply = run_agent('put', chunk_request(offset: -1))

        expect(reply.statuscode).to eq(4)
        expect(reply.statusmsg).to include('The offset input must be at least 0')
        expect(Dir.children(session)).to be_empty
      end

      it 'rejects an offset given as a string and creates nothing' do
        reply = run_agent('put', chunk_request(offset: '0'))

        expect(reply.statuscode).to eq(4)
        expect(reply.statusmsg).to include('The offset input must be an integer')
        expect(Dir.children(session)).to be_empty
      end

      it 'rejects a boolean given as a string and creates nothing' do
        reply = run_agent('put', chunk_request(final: 'true'))

        expect(reply.statuscode).to eq(4)
        expect(reply.statusmsg).to include('The final input must be true or false')
        expect(Dir.children(session)).to be_empty
      end

      {
        'a name of one dot' => '.',
        'a name of two dots' => '..',
        'a name with a parent component' => 'a/../b',
        'a name with a leading parent component' => '../escape.bin',
        'a name with a dot component' => 'a/./b',
        'an absolute name' => '/etc/escape.bin',
        'a name with a trailing slash' => 'a/',
        'a name with an empty component' => 'a//b',
        'a name with a backslash' => 'a\b',
        'a name with a newline' => "a\nfile_transfer cleanup /etc caller=forged",
        'a name with a carriage return' => "a\rb",
        'a name with a tab' => "a\tb",
        'a name with an escape character' => "a\eb",
      }.each do |description, relative_name|
        it "rejects #{description} and creates nothing" do
          reply = run_agent('put', chunk_request(name: relative_name))

          expect(reply.statuscode).to eq(4)
          expect(reply.statusmsg).to include('The name must be a relative path')
          expect(Dir.children(session)).to be_empty
        end
      end
    end

    describe 'the reply of a non-final chunk' do
      it 'neither delivers nor changes the mode when destination and mode arrive before the final chunk' do
        dest_dir = Dir.mktmpdir('file_transfer-dest')
        destination = File.join(dest_dir, 'early.bin')
        reply = run_agent('put', chunk_request(destination: destination, mode: '0755'))

        expect(reply.statuscode).to eq(0)
        expect(File.exist?(destination)).to be(false)
        expect(File.binread(file_path)).to eq('hello')
        expect(mode_of(file_path)).to eq('0600')
      ensure
        FileUtils.remove_entry_secure(dest_dir) if dest_dir
      end

      it 'accepts a sha256 without verifying it and answers a null digest' do
        reply = run_agent('put', chunk_request(sha256: sha256('other content')))

        expect(reply.statuscode).to eq(0)
        expect(reply.data).to eq('bytes' => 5, 'size' => 5, 'sha256' => nil)
        expect(File.binread(file_path)).to eq('hello')
      end
    end
  end
end
