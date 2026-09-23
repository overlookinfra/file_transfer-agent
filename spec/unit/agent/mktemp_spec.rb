# frozen_string_literal: true

require 'find'
require 'spec_helper'

RSpec.describe 'the file_transfer agent mktemp action' do
  include_context 'with an agent root'

  # A second UUID, for the entries a test plants beside the session that
  # mktemp creates.
  let(:planted_uuid) { '9f2c7b1a-4d3e-4a5b-8c6d-1e2f3a4b5c6d' }
  let(:session_path) { session_dir(root, uuid) }
  let(:reply) { run_agent('mktemp', { session: uuid }) }

  describe 'creating a session' do
    it 'creates the session directory under the temp root' do
      expect(reply.statuscode).to eq(0)
      expect(reply.statusmsg).to eq('OK')
      expect(File.directory?(session_path)).to be(true)
    end

    it 'creates the session directory with mode 0700' do
      expect(reply.statuscode).to eq(0)
      expect(mode_of(session_path)).to eq('0700')
    end

    it 'answers the absolute path of the session directory' do
      expect(reply.data).to include('path' => session_path)
    end

    it 'reports no swept sessions when the root holds nothing else' do
      expect(reply.data).to include('swept' => 0)
    end

    it 'exits zero and writes nothing to stderr' do
      expect(reply.exitstatus).to eq(0)
      expect(reply.stderr).to eq('')
    end
  end

  describe 'refusing an entry that is already at the session path' do
    it 'refuses a session path that is already a directory and leaves it untouched' do
      Dir.mkdir(session_path, 0o700)
      File.chmod(0o755, session_path)
      File.write(File.join(session_path, 'chunk.bin'), 'planted')

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(session_path, 'File exists')
      expect(reply.stdout).to eq('')
      expect(mode_of(session_path)).to eq('0755')
      expect(File.read(File.join(session_path, 'chunk.bin'))).to eq('planted')
    end

    it 'refuses a session path that is a regular file and leaves it untouched' do
      File.write(session_path, 'planted')

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(session_path, 'File exists')
      expect(File.file?(session_path)).to be(true)
      expect(File.read(session_path)).to eq('planted')
    end

    it 'refuses a session path that is a symbolic link and leaves the link and its target untouched' do
      target = File.join(root, 'target')
      Dir.mkdir(target, 0o700)
      File.write(File.join(target, 'kept'), 'planted')
      File.symlink(target, session_path)

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include(session_path, 'File exists')
      expect(File.symlink?(session_path)).to be(true)
      expect(File.readlink(session_path)).to eq(target)
      expect(File.read(File.join(target, 'kept'))).to eq('planted')
    end
  end

  describe 'the stale sweep' do
    let(:settings) { { 'tmpdir' => root, 'stale_after' => 100 } }
    let(:stale_path) { session_dir(root, planted_uuid) }

    # File.utime follows symbolic links, so a link is aged through lutime and
    # whatever it points at keeps the times it had.
    def age(path, seconds)
      moment = Time.now - seconds
      return File.lutime(moment, moment, path) if File.symlink?(path)

      File.utime(moment, moment, path)
    end

    # Ages a whole tree deepest first, so that aging a directory is not undone
    # by aging what is inside it. Find does not step through links.
    def age_tree(path, seconds)
      Find.find(path).reverse_each { |entry| age(entry, seconds) }
    end

    # An abandoned session directory whose whole tree is older than the
    # stale_after of these examples.
    def plant_stale_session(session_uuid)
      path = session_dir(root, session_uuid)
      Dir.mkdir(path, 0o700)
      File.write(File.join(path, 'chunk.bin'), 'abandoned')
      age_tree(path, 1000)
      path
    end

    # A stale directory directly under the root whose name is not a session
    # name, holding a file the sweep must leave alone.
    def plant_stale_directory(name)
      path = File.join(root, name)
      Dir.mkdir(path, 0o700)
      File.write(File.join(path, 'chunk.bin'), 'not a session')
      age_tree(path, 1000)
      path
    end

    it 'removes a session whose whole tree is older than stale_after' do
      planted = plant_stale_session(planted_uuid)

      expect(reply.data).to include('swept' => 1)
      expect(File.exist?(planted)).to be(false)
      expect(File.directory?(session_path)).to be(true)
    end

    it 'keeps a session with a fresh file deep in its tree even when its top directory is old' do
      Dir.mkdir(stale_path, 0o700)
      Dir.mkdir(File.join(stale_path, 'modules'), 0o700)
      busy = File.join(stale_path, 'modules', 'run.sh')
      File.write(busy, 'a task is still reading this')
      age_tree(stale_path, 1000)
      File.utime(Time.now, Time.now, busy)

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(stale_path)).to be(true)
      expect(File.read(busy)).to eq('a task is still reading this')
    end

    it 'keeps a session younger than stale_after' do
      Dir.mkdir(stale_path, 0o700)
      File.write(File.join(stale_path, 'chunk.bin'), 'in flight')
      age_tree(stale_path, 50)

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(stale_path)).to be(true)
    end

    it 'keeps a stale symbolic link named like a session and the directory it points at' do
      target = File.join(root, 'target')
      Dir.mkdir(target, 0o700)
      File.write(File.join(target, 'kept'), 'planted')
      File.symlink(target, stale_path)
      age_tree(target, 1000)
      age(stale_path, 1000)

      expect(reply.data).to include('swept' => 0)
      expect(File.symlink?(stale_path)).to be(true)
      expect(File.read(File.join(target, 'kept'))).to eq('planted')
    end

    it 'keeps a stale regular file named like a session' do
      File.write(stale_path, 'not a session')
      age(stale_path, 1000)

      expect(reply.data).to include('swept' => 0)
      expect(File.file?(stale_path)).to be(true)
      expect(File.read(stale_path)).to eq('not a session')
    end

    it 'keeps a stale session directory owned by another user' do
      skip('needs root to change the owner of a directory') unless Process.euid.zero?

      planted = plant_stale_session(planted_uuid)
      File.chown(65_534, 65_534, planted) # nobody, standing in for another user while the tests run as root

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(planted)).to be(true)
      expect(File.stat(planted).uid).to eq(65_534)
      expect(File.read(File.join(planted, 'chunk.bin'))).to eq('abandoned')
    end

    it 'keeps a stale session directory that is readable by its group' do
      planted = plant_stale_session(planted_uuid)
      File.chmod(0o750, planted)

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(planted)).to be(true)
      expect(mode_of(planted)).to eq('0750')
    end

    it 'keeps a stale session directory that is readable by other users' do
      planted = plant_stale_session(planted_uuid)
      File.chmod(0o705, planted)

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(planted)).to be(true)
      expect(mode_of(planted)).to eq('0705')
    end

    it 'keeps a stale tmpdir the shell agent created' do
      planted = plant_stale_directory("bolt-choria-#{planted_uuid}")

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(planted)).to be(true)
      expect(File.read(File.join(planted, 'chunk.bin'))).to eq('not a session')
    end

    it 'keeps a stale directory whose uuid is uppercase' do
      planted = plant_stale_directory("file_transfer-#{planted_uuid.upcase}")

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(planted)).to be(true)
      expect(File.read(File.join(planted, 'chunk.bin'))).to eq('not a session')
    end

    it 'keeps a stale directory whose uuid is truncated' do
      planted = plant_stale_directory("file_transfer-#{planted_uuid[0, 35]}")

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(planted)).to be(true)
      expect(File.read(File.join(planted, 'chunk.bin'))).to eq('not a session')
    end

    it 'keeps a stale directory whose name carries a suffix after the uuid' do
      planted = plant_stale_directory("file_transfer-#{planted_uuid}.old")

      expect(reply.data).to include('swept' => 0)
      expect(File.directory?(planted)).to be(true)
      expect(File.read(File.join(planted, 'chunk.bin'))).to eq('not a session')
    end

    it 'counts every stale session it removes' do
      abandoned = [plant_stale_session(planted_uuid), plant_stale_session(SecureRandom.uuid)]

      expect(reply.data).to include('swept' => 2)
      abandoned.each { |path| expect(File.exist?(path)).to be(false) }
    end

    it 'leaves the temp root in place when every session under it is stale' do
      plant_stale_session(planted_uuid)
      plant_stale_session(SecureRandom.uuid)

      expect(reply.statuscode).to eq(0)
      expect(File.directory?(root)).to be(true)
      expect(Dir.children(root)).to contain_exactly("file_transfer-#{uuid}")
    end

    context 'when a stale session holds a link to a directory outside the root' do
      let(:outside) { Dir.mktmpdir('file_transfer-outside') }

      after { FileUtils.remove_entry_secure(outside) }

      it 'removes the session without touching the link target' do
        File.write(File.join(outside, 'kept'), 'outside the root')
        Dir.mkdir(stale_path, 0o700)
        Dir.mkdir(File.join(stale_path, 'modules'), 0o700)
        File.symlink(outside, File.join(stale_path, 'modules', 'escape'))
        age_tree(stale_path, 1000)

        expect(reply.data).to include('swept' => 1)
        expect(File.exist?(stale_path)).to be(false)
        expect(File.directory?(outside)).to be(true)
        expect(File.read(File.join(outside, 'kept'))).to eq('outside the root')
      end
    end
  end
end
