# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer agent abort action' do
  include_context 'with an agent root'

  let(:destination) { File.join(root, 'file.bin') }
  let(:temp_file) { File.join(root, ".file_transfer-#{token}") }

  before { run_agent('put', { destination: destination, token: token, offset: 0, data: chunk('partial') }) }

  it 'removes the temporary file of the destination and token and answers removed true' do
    reply = run_agent('abort', { destination: destination, token: token })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to eq('removed' => true)
    expect(Dir.children(root)).to be_empty
  end

  it 'answers removed false with status 0 when there is nothing to remove' do
    run_agent('abort', { destination: destination, token: token })

    reply = run_agent('abort', { destination: destination, token: token })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to eq('removed' => false)
  end

  it 'removes nothing for a token that names another file' do
    reply = run_agent('abort', { destination: destination, token: 'ffffffffffffffff' })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to eq('removed' => false)
    expect(File.binread(temp_file)).to eq('partial')
  end

  it 'leaves the destination alone' do
    File.write(destination, 'the file that is there')

    reply = run_agent('abort', { destination: destination, token: token })

    expect(reply.data).to eq('removed' => true)
    expect(File.binread(destination)).to eq('the file that is there')
  end

  it 'refuses a relative destination and a malformed token as put does, and removes nothing' do
    relative = run_agent('abort', { destination: 'file.bin', token: token })
    malformed = run_agent('abort', { destination: destination, token: token.upcase })

    expect(relative.statuscode).to eq(4)
    expect(relative.statusmsg).to include('The destination input must be an absolute path')
    expect(malformed.statuscode).to eq(4)
    expect(malformed.statusmsg).to include('The token must be 16 lowercase hex characters')
    expect(File.binread(temp_file)).to eq('partial')
  end

  it 'answers Aborted and leaves a directory standing at the temporary name' do
    other = SecureRandom.hex(8)
    Dir.mkdir(File.join(root, ".file_transfer-#{other}"))

    reply = run_agent('abort', { destination: destination, token: other })

    expect(reply.statuscode).to eq(1)
    expect(File.directory?(File.join(root, ".file_transfer-#{other}"))).to be(true)
  end
end
