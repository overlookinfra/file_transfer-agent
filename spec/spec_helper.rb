# frozen_string_literal: true

require 'rspec'
require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'timeout'
require 'tmpdir'

FILES_DIR = File.expand_path('../files', __dir__)
AGENT = File.join(FILES_DIR, 'mcollective', 'agent', 'file_transfer')
RPC_PROTOCOL = 'io.choria.mcorpc.external.v1.rpc_request'
ACTIVATION_PROTOCOL = 'io.choria.mcorpc.external.v1.activation_request'

Dir[File.join(__dir__, 'support', '*.rb')].each { |file| require file }

# Every example gets its own directory for destinations, a token for the
# file it puts, and the AgentRunner helpers that run the agent against them.
# The context also gives the destination and the temporary file the token
# names beside it.
RSpec.shared_context 'with an agent root' do
  include AgentRunner

  let(:root) { Dir.mktmpdir('file_transfer-root') }
  let(:token) { SecureRandom.hex(8) }
  let(:destination) { File.join(root, 'file.bin') }
  let(:temp_file) { File.join(root, ".file_transfer-#{token}") }

  after { FileUtils.remove_entry_secure(root) }
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.order = :random
end
