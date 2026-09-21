# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'the file_transfer DDL' do
  uuid = '0f5c1e2a-3b4d-4e6f-8a9b-0c1d2e3f4a5b'
  sha = 'a' * 64
  chunk = ['x' * 555_000].pack('m0')
  empty_chunk = ''

  let(:ddl) { RubyDDL.load('file_transfer') }
  let(:json) { JSON.parse(File.read(File.join(FILES_DIR, 'mcollective', 'agent', 'file_transfer.json'))) }

  it 'declares the same actions in the JSON and Ruby forms' do
    json_actions = json['actions'].map { |action| action['action'] }.sort
    expect(ddl.actions.sort).to eq(json_actions)
  end

  it 'declares the same inputs, outputs, and display in both forms' do
    json['actions'].each do |action|
      interface = ddl.action_interface(action['action'])
      expect(interface[:input].keys.map(&:to_s).sort).to eq(action['input'].keys.sort)
      expect(interface[:output].keys.map(&:to_s).sort).to eq(action['output'].keys.sort)
      expect(interface[:display].to_s).to eq(action['display'])
    end
  end

  it 'declares the same type, optionality, validation, and maxlength for every input in both forms' do
    json['actions'].each do |action|
      interface = ddl.action_interface(action['action'])
      action['input'].each do |name, spec|
        ruby_spec = interface[:input][name.to_sym]
        expect(ruby_spec[:type].to_s).to eq(spec['type']), "#{action['action']}.#{name} type"
        expect(ruby_spec[:optional]).to eq(spec['optional']), "#{action['action']}.#{name} optional"
        next unless spec['type'] == 'string'

        expect(ruby_spec[:validation]).to eq(spec['validation']), "#{action['action']}.#{name} validation"
        expect(ruby_spec[:maxlength]).to eq(spec['maxlength']), "#{action['action']}.#{name} maxlength"
      end
    end
  end

  it 'marks the agent as an external agent for the Choria server' do
    expect(json['metadata']['provider']).to eq('external')
    expect(ddl.meta[:provider]).to eq('external')
  end

  it 'declares the same version and timeout in both forms, and the client library caps its waits at that timeout' do
    expect(ddl.meta[:version]).to eq(json['metadata']['version'])
    expect(ddl.meta[:timeout]).to eq(json['metadata']['timeout'])
    expect(MCollective::Util::FileTransfer::DDL_TIMEOUT).to eq(json['metadata']['timeout'])
  end

  it 'anchors every validation regex and never starts one with a lowercase letter, which the server reads as a validator name' do
    json['actions'].each do |action|
      action['input'].each do |name, spec|
        next unless spec['type'] == 'string'

        expect(spec['validation']).to start_with('\A').and(end_with('\z')), "#{action['action']}.#{name}"
      end
    end
  end

  it 'gives every string input a non-zero maxlength so the Choria server applies the regex' do
    json['actions'].each do |action|
      action['input'].each do |name, spec|
        next unless spec['type'] == 'string'

        expect(spec['maxlength']).to be_positive, "#{action['action']}.#{name}"
      end
    end
  end

  accepted = {
    'mktemp with a session' => ['mktemp', { session: uuid }],
    'cleanup with a session' => ['cleanup', { session: uuid }],
    'a first chunk' => ['put', { session: uuid, name: 'file.bin', offset: 0, data: chunk }],
    'a final chunk with a destination and mode' => [
      'put', { session: uuid, name: 'file.bin', offset: 555_000, data: chunk, final: true,
               sha256: sha, destination: '/etc/app/file.bin', mode: '0644' }
    ],
    'an empty final chunk' => ['put', { session: uuid, name: 'args.json', offset: 0, data: empty_chunk, final: true, sha256: sha, mode: '0600' }],
    'a name with directories' => ['put', { session: uuid, name: 'modules/mymod/files/run.sh', offset: 0, data: empty_chunk }],
    'a hidden file name' => ['put', { session: uuid, name: '.hidden', offset: 0, data: empty_chunk }],
    'a name starting with two dots' => ['put', { session: uuid, name: '..two', offset: 0, data: empty_chunk }],
    'a name of three dots' => ['put', { session: uuid, name: '...', offset: 0, data: empty_chunk }],
    'dotted components' => ['put', { session: uuid, name: 'a.b/c.d', offset: 0, data: empty_chunk }],
    'a name with spaces and non-ASCII letters' => ['put', { session: uuid, name: "my files/café au lait.txt", offset: 0, data: empty_chunk }],
    'a Windows destination' => [
      'put', { session: uuid, name: 'file.bin', offset: 0, data: empty_chunk, destination: 'C:\\app\\file.bin', final: true, sha256: sha }
    ],
    'get' => ['get', { path: '/tmp/x', offset: 0, max_bytes: 555_000 }],
    'stat' => ['stat', { path: '/tmp/x' }],
    'stat of a Windows path with checksum' => ['stat', { path: 'C:\\Windows\\Temp\\x', checksum: true }],
    'list with paging' => ['list', { path: '/tmp', offset: 0, limit: 100 }],
    'list without paging' => ['list', { path: '/tmp' }],
    'mkdir with a mode' => ['mkdir', { path: '/tmp/d', mode: '0700' }],
    'mkdir without a mode' => ['mkdir', { path: '/tmp/d' }],
  }

  rejected = {
    'an uppercase session' => ['mktemp', { session: uuid.upcase }],
    'a session with the directory prefix' => ['mktemp', { session: "file_transfer-#{uuid}" }],
    'a session given as a path' => ['mktemp', { session: "/tmp/file_transfer-#{uuid}" }],
    'mktemp without a session' => ['mktemp', {}],
    'cleanup of a path' => ['cleanup', { session: "/tmp/file_transfer-#{uuid}" }],
    'cleanup of the root' => ['cleanup', { session: '/' }],
    'a session with a trailing slash' => ['cleanup', { session: "#{uuid}/" }],
    'a session with a trailing newline' => ['cleanup', { session: "#{uuid}\n" }],
    'a session with a parent reference' => ['cleanup', { session: "../#{uuid}" }],
    'a truncated session' => ['cleanup', { session: uuid[0, 35] }],
    'cleanup with a path input' => ['cleanup', { path: "/tmp/file_transfer-#{uuid}" }],
    'a name of one dot' => ['put', { session: uuid, name: '.', offset: 0, data: empty_chunk }],
    'a name of two dots' => ['put', { session: uuid, name: '..', offset: 0, data: empty_chunk }],
    'a name with a parent component' => ['put', { session: uuid, name: 'a/../b', offset: 0, data: empty_chunk }],
    'a name with a leading parent component' => ['put', { session: uuid, name: '../b', offset: 0, data: empty_chunk }],
    'a name with a dot component' => ['put', { session: uuid, name: 'a/./b', offset: 0, data: empty_chunk }],
    'an absolute name' => ['put', { session: uuid, name: '/a', offset: 0, data: empty_chunk }],
    'a name with a trailing slash' => ['put', { session: uuid, name: 'a/', offset: 0, data: empty_chunk }],
    'a name with an empty component' => ['put', { session: uuid, name: 'a//b', offset: 0, data: empty_chunk }],
    'a name with a backslash' => ['put', { session: uuid, name: 'a\\b', offset: 0, data: empty_chunk }],
    'an empty name' => ['put', { session: uuid, name: '', offset: 0, data: empty_chunk }],
    'a name with a drive letter' => ['put', { session: uuid, name: 'C:\\x', offset: 0, data: empty_chunk }],
    'a name with a newline' => ['put', { session: uuid, name: "a\nfile_transfer cleanup /x caller=y", offset: 0, data: empty_chunk }],
    'a name with a carriage return' => ['put', { session: uuid, name: "a\rb", offset: 0, data: empty_chunk }],
    'a name with a tab' => ['put', { session: uuid, name: "a\tb", offset: 0, data: empty_chunk }],
    'a name with a delete character' => ['put', { session: uuid, name: "a\x7fb", offset: 0, data: empty_chunk }],
    'put with a path input' => ['put', { path: '/tmp/x', offset: 0, data: empty_chunk }],
    'data that is not base64' => ['put', { session: uuid, name: 'x', offset: 0, data: 'not base64!' }],
    'data with a newline' => ['put', { session: uuid, name: 'x', offset: 0, data: "#{chunk}\n" }],
    'data above 64 MiB' => ['put', { session: uuid, name: 'x', offset: 0, data: 'A' * 67_108_868 }],
    'a malformed sha256' => ['put', { session: uuid, name: 'x', offset: 0, data: empty_chunk, sha256: 'zz' }],
    'an uppercase sha256' => ['put', { session: uuid, name: 'x', offset: 0, data: empty_chunk, sha256: sha.upcase }],
    'a string offset' => ['put', { session: uuid, name: 'x', offset: '0', data: empty_chunk }],
    'a mode with a digit above 7' => ['put', { session: uuid, name: 'x', offset: 0, data: empty_chunk, mode: '0999' }],
    'a string final flag' => ['put', { session: uuid, name: 'x', offset: 0, data: empty_chunk, final: 'yes' }],
    'an empty destination' => ['put', { session: uuid, name: 'x', offset: 0, data: empty_chunk, destination: '' }],
    'put without data' => ['put', { session: uuid, name: 'x', offset: 0 }],
    'an integer mode' => ['mkdir', { path: '/tmp/d', mode: 493 }],
    'get without max_bytes' => ['get', { path: '/tmp/x', offset: 0 }],
    'a float max_bytes' => ['get', { path: '/tmp/x', offset: 0, max_bytes: 1.5 }],
    'a string limit' => ['list', { path: '/tmp', limit: '10' }],
    'stat without a path' => ['stat', {}],
    'a path with a newline' => ['stat', { path: "/tmp/a\nb" }],
    'an unknown action' => ['delete', { path: '/tmp/x' }],
  }

  describe 'request validation on the client' do
    accepted.each do |description, (action, arguments)|
      it "accepts #{description}" do
        expect { ddl.validate_rpc_request(action, arguments) }.not_to raise_error
      end
    end

    rejected.each do |description, (action, arguments)|
      it "rejects #{description}" do
        expect { ddl.validate_rpc_request(action, arguments) }.to raise_error(MCollective::DDLValidationError)
      end
    end
  end
end
