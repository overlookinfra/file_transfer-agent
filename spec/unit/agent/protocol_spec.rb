# frozen_string_literal: true

require 'spec_helper'

# A temp root the agent refuses is refused the same way by every action that
# has to resolve a session under it.
RSpec.shared_examples 'a refused temp root' do
  it 'refuses mktemp and names the setting' do
    reply = run_agent('mktemp', { 'session' => uuid })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('tmpdir', bad_tmpdir)
    expect(reply.data).to be_empty
  end

  it 'refuses put and names the setting' do
    reply = run_agent('put', { 'session' => uuid, 'name' => 'file.bin', 'offset' => 0, 'data' => '' })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('tmpdir', bad_tmpdir)
  end

  it 'refuses cleanup and names the setting' do
    reply = run_agent('cleanup', { 'session' => uuid })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('tmpdir', bad_tmpdir)
  end
end

RSpec.describe 'the file_transfer protocol' do
  include_context 'with an agent root'

  describe 'activation' do
    it 'answers an activation request with activate true even though argv names the rpc protocol' do
      reply = run_agent('mktemp', { 'session' => uuid }, protocol: ACTIVATION_PROTOCOL)

      expect(reply.raw).to eq('activate' => true)
      expect(reply.exitstatus).to eq(0)
      expect(reply.stderr).to be_empty
    end

    context 'when the settings file is unusable' do
      let(:settings) { { 'tmpdir' => File.join(root, 'missing'), 'stale_after' => 'never' } }

      it 'still answers with activate true' do
        reply = run_agent('mktemp', { 'session' => uuid }, protocol: ACTIVATION_PROTOCOL)

        expect(reply.raw).to eq('activate' => true)
      end
    end
  end

  describe 'the reply for a request that fails' do
    it 'exits zero and writes a reply carrying all three protocol keys' do
      reply = run_agent('put', { 'session' => uuid, 'name' => 'file.bin', 'offset' => 0, 'data' => '' })

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

    it 'reports a request file that is not JSON as UnknownError with the error and its backtrace on stderr' do
      reply = run_agent('get', {}, request_body: 'this is not a request')

      expect(reply.exitstatus).to eq(0)
      expect(reply.statuscode).to eq(5)
      expect(reply.statusmsg).to start_with('JSON::ParserError:')
      expect(reply.data).to eq({})
      expect(reply.stderr).to start_with('file_transfer: JSON::ParserError:')
      expect(reply.stderr.lines.length).to be > 1
      expect(reply.stderr.lines[1]).to include('.rb:')
    end

    it 'answers a request whose data is a string instead of an object' do
      reply = run_agent('mktemp', 'not an object')

      expect(reply.exitstatus).to eq(0)
      expect(reply.statuscode).to eq(3)
      expect(reply.statusmsg).to include('session')
    end

    it 'answers a request whose data is null' do
      reply = run_agent('mktemp', nil)

      expect(reply.exitstatus).to eq(0)
      expect(reply.statuscode).to eq(3)
      expect(reply.statusmsg).to include('session')
    end
  end

  describe 'the request data' do
    it 'ignores the process_results key the client adds' do
      reply = run_agent('mktemp', { 'session' => uuid, 'process_results' => true })

      expect(reply.statuscode).to eq(0)
      expect(reply.data['path']).to eq(session_dir(root, uuid))
      expect(File).to be_directory(session_dir(root, uuid))
    end
  end

  describe 'the settings file' do
    it 'reads the tmpdir setting from the .cfg file the Puppet module writes' do
      reply = run_agent('mktemp', { 'session' => uuid })

      expect(reply.statuscode).to eq(0)
      expect(reply.data['path']).to eq(session_dir(root, uuid))
    end

    context 'when the settings live at the exact path CHORIA_EXTERNAL_CONFIG names' do
      let(:config) { write_config(config_dir, settings, extension: '') }

      it 'reads the tmpdir setting from that file' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(reply.data['path']).to eq(session_dir(root, uuid))
      end
    end

    it 'prefers the settings at the exact path over the .cfg variant' do
      ignored_root = File.join(root, 'ignored')
      Dir.mkdir(ignored_root)
      write_config(config_dir, { 'tmpdir' => ignored_root }, extension: '.cfg')
      exact = write_config(config_dir, { 'tmpdir' => root }, extension: '')

      reply = run_agent('mktemp', { 'session' => uuid }, config: exact)

      expect(reply.data['path']).to eq(session_dir(root, uuid))
      expect(File).not_to exist(session_dir(ignored_root, uuid))
    end

    it 'ignores comments and blank lines in the settings file' do
      File.write("#{config}.cfg", "# where the sessions live\n\n   \ntmpdir = #{root}\n\n# stale_after = never\n")

      reply = run_agent('mktemp', { 'session' => uuid })

      expect(reply.statuscode).to eq(0)
      expect(reply.data['path']).to eq(session_dir(root, uuid))
    end

    it 'reads the settings that follow a non-ASCII comment' do
      File.write("#{config}.cfg", "# café wrote this\ntmpdir = #{root}\n")

      reply = run_agent('mktemp', { 'session' => uuid })

      expect(reply.statuscode).to eq(0)
      expect(reply.data['path']).to eq(session_dir(root, uuid))
    end

    context 'when there is no settings file at all' do
      # The agent runs without TMPDIR in its environment, so its Dir.tmpdir is
      # the system temp dir the spec process sees as well.
      let(:config) { File.join(config_dir, 'plugin.d', 'file_transfer') }

      it 'creates the session under the Ruby temp dir' do
        reply = run_agent('mktemp', { 'session' => uuid })
        removal = run_agent('cleanup', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(reply.data['path']).to eq(session_dir(Dir.tmpdir, uuid))
        expect(removal.data['removed']).to be(true)
      end
    end
  end

  describe 'the stale_after setting' do
    context 'when it is not a number' do
      let(:settings) { { 'tmpdir' => root, 'stale_after' => 'tomorrow' } }

      it 'refuses mktemp, names the setting, and creates nothing' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(1)
        expect(reply.statusmsg).to include('stale_after', 'tomorrow')
        expect(reply.stdout).to eq('')
        expect(Dir.children(root)).to be_empty
      end

      it 'leaves put, cleanup, get, stat, list, and mkdir unaffected' do
        Dir.mkdir(session_dir(root, uuid), 0o700)
        replies = {
          put: run_agent('put', { 'session' => uuid, 'name' => 'f', 'offset' => 0, 'data' => chunk('') }),
          stat: run_agent('stat', { 'path' => root }),
          list: run_agent('list', { 'path' => root }),
          mkdir: run_agent('mkdir', { 'path' => File.join(root, 'made') }),
          get: run_agent('get', { 'path' => File.join(session_dir(root, uuid), 'f'), 'offset' => 0, 'max_bytes' => 1 }),
          cleanup: run_agent('cleanup', { 'session' => uuid }),
        }

        expect(replies.transform_values(&:statuscode)).to eq(put: 0, stat: 0, list: 0, mkdir: 0, get: 0, cleanup: 0)
        expect(File.directory?(File.join(root, 'made'))).to be(true)
        expect(replies[:cleanup].data).to eq('removed' => true)
        expect(replies[:stat].data['type']).to eq('directory')
        expect(replies[:list].data['total']).to eq(1)
        expect(replies[:get].data).to include('bytes' => 0, 'eof' => true)
      end
    end

    context 'when it is zero' do
      let(:settings) { { 'tmpdir' => root, 'stale_after' => 0 } }

      it 'refuses mktemp, names the setting, and creates nothing' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(1)
        expect(reply.statusmsg).to include('stale_after')
        expect(Dir.children(root)).to be_empty
      end
    end

    context 'when it has a leading zero' do
      let(:settings) { { 'tmpdir' => root, 'stale_after' => '0600' } }

      it 'reads it in base ten and keeps a session younger than that many seconds' do
        planted = session_dir(root, '9f2c7b1a-4d3e-4a5b-8c6d-1e2f3a4b5c6d')
        Dir.mkdir(planted, 0o700)
        aged = Time.now - 500
        File.utime(aged, aged, planted)

        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(reply.data['swept']).to eq(0)
        expect(File.directory?(planted)).to be(true)
      end
    end

    context 'when it is a number of seconds' do
      let(:settings) { { 'tmpdir' => root, 'stale_after' => 60 } }

      it 'creates the session and sweeps nothing' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(reply.data['swept']).to eq(0)
      end
    end
  end

  describe 'the tmpdir setting' do
    let(:settings) { { 'tmpdir' => bad_tmpdir } }

    context 'when it is a relative path' do
      let(:bad_tmpdir) { 'file_transfer-relative-root' }

      it_behaves_like 'a refused temp root'
    end

    context 'when it names nothing' do
      let(:bad_tmpdir) { File.join(root, 'missing') }

      it_behaves_like 'a refused temp root'
    end

    context 'when it names a regular file' do
      let(:bad_tmpdir) do
        path = File.join(root, 'not-a-directory')
        File.write(path, 'x')
        path
      end

      it_behaves_like 'a refused temp root'
    end

    context 'when it names a world writable directory without the sticky bit' do
      let(:bad_tmpdir) do
        path = File.join(root, 'world-writable')
        Dir.mkdir(path)
        File.chmod(0o777, path)
        path
      end

      it_behaves_like 'a refused temp root'
    end

    context 'when it names a world writable directory with the sticky bit' do
      let(:sticky_root) do
        path = File.join(root, 'sticky')
        Dir.mkdir(path)
        File.chmod(0o1777, path)
        path
      end
      let(:settings) { { 'tmpdir' => sticky_root } }

      it 'creates the session there with mode 0700' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(reply.data['path']).to eq(session_dir(sticky_root, uuid))
        expect(mode_of(session_dir(sticky_root, uuid))).to eq('0700')
      end
    end

    context 'when it names a directory owned by another user' do
      let(:bad_tmpdir) do
        path = File.join(root, 'foreign')
        Dir.mkdir(path, 0o755)
        File.chown(65_534, 65_534, path)
        path
      end

      it_behaves_like 'a refused temp root'
    end

    context 'when it names a directory that its group can write to without the sticky bit' do
      let(:bad_tmpdir) do
        path = File.join(root, 'group-writable')
        Dir.mkdir(path)
        File.chmod(0o775, path)
        path
      end

      it_behaves_like 'a refused temp root'
    end

    context 'when it names a directory only its owner can write to' do
      let(:private_root) do
        path = File.join(root, 'private')
        Dir.mkdir(path)
        File.chmod(0o755, path)
        path
      end
      let(:settings) { { 'tmpdir' => private_root } }

      it 'creates the session there' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(reply.data['path']).to eq(session_dir(private_root, uuid))
      end
    end

    context 'when it reaches the directory through a symbolic link' do
      let(:real_root) do
        path = File.join(root, 'real')
        Dir.mkdir(path, 0o700)
        path
      end
      let(:settings) do
        File.symlink(real_root, File.join(root, 'link'))
        { 'tmpdir' => File.join(root, 'link') }
      end

      it 'works under the resolved directory and answers its real path' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(reply.data['path']).to eq(session_dir(File.realpath(real_root), uuid))
        expect(File.directory?(session_dir(real_root, uuid))).to be(true)
      end
    end

    context 'when it names a directory with non-ASCII characters' do
      let(:accented_root) do
        path = File.join(root, "café")
        Dir.mkdir(path, 0o700)
        path
      end
      let(:settings) { { 'tmpdir' => accented_root, 'stale_after' => 60 } }

      it 'creates the session there' do
        reply = run_agent('mktemp', { 'session' => uuid })

        expect(reply.statuscode).to eq(0)
        expect(File.directory?(session_dir(accented_root, uuid))).to be(true)
      end
    end
  end

  describe 'the process output' do
    # The server logs stdout at INFO and stderr at ERROR, so a request that
    # succeeds writes nothing to either.
    it 'stays quiet for a successful mktemp, put, stat, and cleanup' do
      source = File.join(root, 'source.bin')
      File.write(source, 'hello')
      replies = [
        run_agent('mktemp', { 'session' => uuid }),
        run_agent('put', { 'session' => uuid, 'name' => 'file.bin', 'offset' => 0, 'data' => chunk('hello'), 'final' => true,
                           'sha256' => sha256('hello') }),
        run_agent('stat', { 'path' => source }),
        run_agent('cleanup', { 'session' => uuid }),
      ]

      expect(replies.map(&:statuscode)).to eq([0, 0, 0, 0])
      expect(replies.map(&:stdout)).to all(be_empty)
      expect(replies.map(&:stderr)).to all(be_empty)
    end
  end
end
