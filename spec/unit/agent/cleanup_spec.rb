# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer cleanup action' do
  include_context 'with an agent root'

  let(:session) { session_dir(root, uuid) }

  describe 'removing a session the agent created' do
    before { run_agent('mktemp', { 'session' => uuid }) }

    it 'removes the session directory with every file and directory inside it' do
      nested = File.join(session, 'modules', 'mymod', 'files')
      FileUtils.mkdir_p(nested, mode: 0o700)
      File.write(File.join(nested, 'run.sh'), "#!/bin/sh\necho hi\n")
      File.write(File.join(session, 'args.json'), '{"message":"hello"}')

      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.statuscode).to eq(0)
      expect(reply.statusmsg).to eq('OK')
      expect(reply.data).to eq('removed' => true)
      expect(reply.stderr).to eq('')
      expect(Dir.children(root)).to be_empty
    end

    it 'removes only the named session and leaves the other entries in the root' do
      other = SecureRandom.uuid
      run_agent('mktemp', { 'session' => other })
      File.write(File.join(root, 'notes.txt'), 'unrelated')
      Dir.mkdir(File.join(root, 'bolt-choria-2f8c'), 0o700)

      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.data).to eq('removed' => true)
      expect(Dir.children(root).sort).to eq(['bolt-choria-2f8c', "file_transfer-#{other}", 'notes.txt'])
    end
  end

  describe 'sessions and symbolic links' do
    let(:outside) { Dir.mktmpdir('file_transfer-outside') }
    let(:kept_file) { File.join(outside, 'keep.txt') }

    before { File.write(kept_file, 'keep me') }

    after { FileUtils.remove_entry_secure(outside) }

    it 'removes a session whose subdirectory holds a link to a directory outside the root, leaving the target intact' do
      run_agent('mktemp', { 'session' => uuid })
      nested = File.join(session, 'nested')
      Dir.mkdir(nested, 0o700)
      File.symlink(outside, File.join(nested, 'link'))

      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('removed' => true)
      expect(File.exist?(session)).to be(false)
      expect(File.directory?(outside)).to be(true)
      expect(File.read(kept_file)).to eq('keep me')
    end

    it 'refuses a session path that is a symbolic link and leaves the link and its target in place' do
      File.symlink(outside, session)

      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(session, 'is a symbolic link')
      expect(reply.data).to eq({})
      expect(reply.stdout).to eq('')
      expect(File.symlink?(session)).to be(true)
      expect(File.read(kept_file)).to eq('keep me')
    end
  end

  describe 'refusing whatever else sits at the session path' do
    it 'refuses a regular file and leaves its content in place' do
      File.write(session, 'planted')

      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(session, 'is not a directory')
      expect(reply.data).to eq({})
      expect(reply.stdout).to eq('')
      expect(reply.exitstatus).to eq(0)
      expect(File.read(session)).to eq('planted')
    end

    it 'refuses a directory owned by another user and leaves it and its content in place' do
      Dir.mkdir(session, 0o700)
      File.write(File.join(session, 'planted.txt'), 'planted')
      File.chown(65_534, 65_534, session)

      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(session, "is not owned by the agent's user")
      expect(reply.stdout).to eq('')
      expect(File.directory?(session)).to be(true)
      expect(File.read(File.join(session, 'planted.txt'))).to eq('planted')
    end

    { 'the group' => 0o750, 'other users' => 0o701 }.each do |who, mode|
      it "refuses a directory that #{who} can reach and leaves it in place" do
        Dir.mkdir(session, 0o700)
        File.write(File.join(session, 'planted.txt'), 'planted')
        File.chmod(mode, session)

        reply = run_agent('cleanup', { 'session' => uuid })

        expect(reply.statuscode).to eq(1)
        expect(reply.statusmsg).to include(session, 'accessible to other users')
        expect(reply.stdout).to eq('')
        expect(mode_of(session)).to eq(format('%04o', mode))
        expect(File.read(File.join(session, 'planted.txt'))).to eq('planted')
      end
    end
  end

  describe 'a session id the agent will not map to a path' do
    before { run_agent('mktemp', { 'session' => uuid }) }

    it 'rejects an uppercase session id and removes nothing' do
      reply = run_agent('cleanup', { 'session' => uuid.upcase })

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('lowercase UUID')
      expect(reply.data).to eq({})
      expect(reply.stdout).to eq('')
      expect(File.directory?(session)).to be(true)
    end

    it 'rejects a session id given as the absolute path of the session directory and removes nothing' do
      reply = run_agent('cleanup', { 'session' => session })

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('lowercase UUID')
      expect(reply.stdout).to eq('')
      expect(File.directory?(session)).to be(true)
    end

    it 'rejects a session id with a trailing slash and removes nothing' do
      reply = run_agent('cleanup', { 'session' => "#{uuid}/" })

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('lowercase UUID')
      expect(reply.stdout).to eq('')
      expect(File.directory?(session)).to be(true)
    end

    it 'rejects a session id with a parent reference and removes nothing' do
      reply = run_agent('cleanup', { 'session' => "../#{uuid}" })

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('lowercase UUID')
      expect(reply.stdout).to eq('')
      expect(File.directory?(session)).to be(true)
    end
  end

  describe 'a session that is not there' do
    it 'answers removed false with status 0' do
      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.statuscode).to eq(0)
      expect(reply.statusmsg).to eq('OK')
      expect(reply.data).to eq('removed' => false)
      expect(reply.stdout).to eq('')
      expect(reply.stderr).to eq('')
      expect(reply.exitstatus).to eq(0)
    end

    it 'answers removed false when the same session is cleaned up twice' do
      run_agent('mktemp', { 'session' => uuid })
      run_agent('cleanup', { 'session' => uuid })

      reply = run_agent('cleanup', { 'session' => uuid })

      expect(reply.statuscode).to eq(0)
      expect(reply.data).to eq('removed' => false)
    end
  end
end
