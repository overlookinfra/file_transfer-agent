# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe 'the file_transfer DDL' do
  token = '0f5c1e2a3b4d4e6f'
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

  it 'declares the same version and timeout in both forms' do
    expect(ddl.meta[:version]).to eq(json['metadata']['version'])
    expect(ddl.meta[:timeout]).to eq(json['metadata']['timeout'])
  end

  it 'anchors every validation regex and never starts one with a lowercase letter, which the server reads as a validator name' do
    json['actions'].each do |action|
      action['input'].each do |name, spec|
        next unless spec['type'] == 'string'

        expect(spec['validation']).to start_with('\A').and(end_with('\z')), "#{action['action']}.#{name}"
      end
    end
  end

  it 'declares no default for any output, since the server fills defaults into refused replies too and a refused put with a sha256 reads as a checksum mismatch' do
    json['actions'].each do |action|
      action['output'].each do |name, spec|
        expect(spec).not_to have_key('default'), "#{action['action']}.#{name}"
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
    'a first chunk' => ['put', { destination: '/etc/app/file.bin', token: token, offset: 0, data: chunk }],
    'a final chunk with a mode' => [
      'put', { destination: '/etc/app/file.bin', token: token, offset: 555_000, data: chunk, final: true, sha256: sha, mode: '0644' }
    ],
    'an empty final chunk' => ['put', { destination: '/etc/app/args.json', token: token, offset: 0, data: empty_chunk, final: true, sha256: sha, mode: '0600' }],
    'a destination with spaces and non-ASCII letters' => ['put', { destination: '/srv/my files/café au lait.txt', token: token, offset: 0, data: empty_chunk }],
    'a Windows destination' => ['put', { destination: 'C:\\app\\file.bin', token: token, offset: 0, data: empty_chunk, final: true, sha256: sha }],
    'abort' => ['abort', { destination: '/etc/app/file.bin', token: token }],
    'abort of a Windows destination' => ['abort', { destination: 'C:\\app\\file.bin', token: token }],
    'get' => ['get', { path: '/tmp/x', offset: 0, max_bytes: 555_000 }],
    'stat' => ['stat', { path: '/tmp/x' }],
    'stat of a Windows path with checksum' => ['stat', { path: 'C:\\Windows\\Temp\\x', checksum: true }],
    'list' => ['list', { path: '/tmp', max_bytes: 524_288 }],
    'list with checksum' => ['list', { path: '/tmp', max_bytes: 524_288, checksum: true }],
    'mkdir with a mode' => ['mkdir', { path: '/tmp/d', mode: '0700' }],
    'mkdir without a mode' => ['mkdir', { path: '/tmp/d' }],
  }

  rejected = {
    'a token of 15 characters' => ['put', { destination: '/x', token: token[0, 15], offset: 0, data: empty_chunk }],
    'a token of 17 characters' => ['put', { destination: '/x', token: "#{token}0", offset: 0, data: empty_chunk }],
    'an uppercase token' => ['put', { destination: '/x', token: token.upcase, offset: 0, data: empty_chunk }],
    'a token with a slash' => ['put', { destination: '/x', token: "#{token[0, 15]}/", offset: 0, data: empty_chunk }],
    'a token with a trailing newline' => ['abort', { destination: '/x', token: "#{token}\n" }],
    'put without a token' => ['put', { destination: '/x', offset: 0, data: empty_chunk }],
    'put without a destination' => ['put', { token: token, offset: 0, data: empty_chunk }],
    'an empty destination' => ['put', { destination: '', token: token, offset: 0, data: empty_chunk }],
    'a destination with a newline' => ['put', { destination: "/x\ny", token: token, offset: 0, data: empty_chunk }],
    'abort without a token' => ['abort', { destination: '/x' }],
    'abort without a destination' => ['abort', { token: token }],
    'list without max_bytes' => ['list', { path: '/tmp' }],
    'a string max_bytes for list' => ['list', { path: '/tmp', max_bytes: '10' }],
    'data that is not base64' => ['put', { destination: '/x', token: token, offset: 0, data: 'not base64!' }],
    'data with a newline' => ['put', { destination: '/x', token: token, offset: 0, data: "#{chunk}\n" }],
    'data above 64 MiB' => ['put', { destination: '/x', token: token, offset: 0, data: 'A' * 67_108_868 }],
    'a malformed sha256' => ['put', { destination: '/x', token: token, offset: 0, data: empty_chunk, sha256: 'zz' }],
    'an uppercase sha256' => ['put', { destination: '/x', token: token, offset: 0, data: empty_chunk, sha256: sha.upcase }],
    'a string offset' => ['put', { destination: '/x', token: token, offset: '0', data: empty_chunk }],
    'a mode with a digit above 7' => ['put', { destination: '/x', token: token, offset: 0, data: empty_chunk, mode: '0999' }],
    'a string final flag' => ['put', { destination: '/x', token: token, offset: 0, data: empty_chunk, final: 'yes' }],
    'put without data' => ['put', { destination: '/x', token: token, offset: 0 }],
    'an integer mode' => ['mkdir', { path: '/tmp/d', mode: 493 }],
    'get without max_bytes' => ['get', { path: '/tmp/x', offset: 0 }],
    'a float max_bytes' => ['get', { path: '/tmp/x', offset: 0, max_bytes: 1.5 }],
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
