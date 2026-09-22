# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::Session do
  include_context 'with a file transfer client'

  let(:content) { 'task body ' * 900 }
  let(:task_file) { local_file('task.sh', content, mode: 0o755) }

  before do
    stub_session
    stub_put
  end

  describe 'opening' do
    it 'creates the session on every node and answers its id and the path each node named' do
      session = client.open_session(nodes)

      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(session.active).to eq(nodes)
      expect(session.paths).to eq(node1 => "/tmp/file_transfer-#{session.id}", node2 => "/tmp/file_transfer-#{session.id}")
      expect(session.failures).to be_empty
      expect(rpc.calls.map(&:first)).to eq([:put, :put, :mktemp])
    end

    it 'drops a node whose mktemp failed into the failures and keeps the rest' do
      rpc.on(:mktemp) do |args, names|
        names.map do |name|
          next rpc_result(name, {}, statuscode: 1, statusmsg: 'Read-only file system') if name == node2

          rpc_result(name, { path: "/tmp/file_transfer-#{args[:session]}" })
        end
      end

      session = client.open_session(nodes)

      expect(session.active).to eq([node1])
      expect(session.paths.keys).to eq([node1])
      expect(session.failures[node2].kind).to eq(:transfer_failed)
      expect(session.failures[node2].message).to include('Read-only file system')
    end

    it 'keeps a node whose mktemp named no path out of the session but in the paths for its cleanup' do
      rpc.on(:mktemp) { |_args, names| results_for(names, { path: nil, swept: 0 }) }

      session = client.open_session([node1])

      expect(session.active).to be_empty
      expect(session.paths).to eq(node1 => nil)
      expect(session.failures[node1].message).to include('without a session path')
    end

    context 'when the broker limit leaves no room for a chunk' do
      let(:max_payload) { 30_000 }

      it 'fails every node before creating anything' do
        session = client.open_session(nodes)

        expect(session.active).to be_empty
        expect(session.failures.values.map(&:kind).uniq).to eq([:payload_too_large])
        expect(rpc.calls.map(&:first)).not_to include(:mktemp)
      end
    end
  end

  describe '#put' do
    it 'sends the file into the session without a destination and answers the nodes that received it' do
      session = client.open_session(nodes)

      delivered = session.put(task_file, 'mymod/tasks/task.sh')

      expect(delivered).to eq(nodes)
      final = chunks.last
      expect(final).to include(session: session.id, name: 'mymod/tasks/task.sh', final: true, mode: '0755', sha256: Digest::SHA256.hexdigest(content))
      expect(final).not_to have_key(:destination)
      expect(decoded(final)).to eq(content)
      expect(session.active).to eq(nodes)
    end

    it 'applies the mode it is given instead of the source mode' do
      session = client.open_session(nodes)

      session.put(task_file, 'args.json', mode: '0600')

      expect(chunks.last[:mode]).to eq('0600')
    end

    it 'sends only to the identities it is given' do
      session = client.open_session(nodes)

      delivered = session.put(task_file, 'args-1.json', identities: [node2])

      expect(delivered).to eq([node2])
      expect(chunks.map { |call| call[:identities] }).to eq([[node2]])
    end

    it 'drops a node that refused the file and keeps the rest in the session' do
      session = client.open_session(nodes)
      stub_put do |_args, names|
        names.map do |name|
          next rpc_result(name, {}, statuscode: 1, statusmsg: 'No space left on device') if name == node2

          rpc_result(name, {})
        end
      end

      delivered = session.put(task_file, 'task.sh')

      expect(delivered).to eq([node1])
      expect(session.active).to eq([node1])
      expect(session.failures[node2].message).to include('No space left on device')
    end
  end

  describe '#cleanup' do
    it 'removes the session on every node' do
      cleaned = []
      rpc.on(:cleanup) do |args, names|
        cleaned << [args[:session], names]
        results_for(names, { removed: true })
      end
      session = client.open_session(nodes)

      session.cleanup

      expect(cleaned).to eq([[session.id, nodes]])
      expect(log.warnings).to be_empty
    end

    context 'when the cleanup option is off for one node' do
      let(:client_options) { { cleanup: { node2 => false } } }

      it 'leaves the session on that node and says the agent sweeps it' do
        cleaned = []
        rpc.on(:cleanup) do |_args, names|
          cleaned << names
          results_for(names, { removed: true })
        end
        session = client.open_session(nodes)

        session.cleanup

        expect(cleaned).to eq([[node1]])
        expect(log.warnings).to include(a_string_including("Leaving session #{session.id} on #{node2}", 'stale_after'))
      end
    end

    it 'warns when the session was gone before its cleanup' do
      rpc.on(:cleanup) { |_args, names| results_for(names, { removed: false }) }
      session = client.open_session([node1])

      session.cleanup

      expect(log.warnings).to include(a_string_including("Session #{session.id} on #{node1} was gone before its cleanup"))
    end

    it 'does not warn about the sweep for a node whose mktemp named no path' do
      rpc.on(:mktemp) { |_args, names| results_for(names, { path: nil, swept: 0 }) }
      cleaned = []
      rpc.on(:cleanup) do |_args, names|
        cleaned << names
        results_for(names, { removed: false })
      end
      session = client.open_session([node1])

      session.cleanup

      expect(cleaned).to eq([[node1]])
      expect(log.warnings).not_to include(a_string_including('stale_after'))
    end

    it 'warns about a cleanup the agent refused' do
      rpc.on(:cleanup) { |_args, names| results_for(names, {}, statuscode: 1, statusmsg: 'Permission denied') }
      session = client.open_session([node1])

      session.cleanup

      expect(log.warnings).to include(a_string_including("Cleanup of session #{session.id} on #{node1} failed", 'Permission denied'))
    end

    it 'reports the chunk reductions the session saw' do
      attempts = 0
      stub_put do |_args, names|
        attempts += 1
        attempts == 1 ? [] : results_for(names)
      end
      stub_ping
      session = client.open_session(nodes)
      session.put(task_file, 'task.sh')

      session.cleanup

      expect(log.warnings).to include('File transfer chunk reductions this run: silent 1')
    end
  end
end
