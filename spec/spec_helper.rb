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

# Every example gets its own temp root for sessions, a config that points
# the agent at it, a fresh session UUID, and the AgentRunner helpers that
# run the agent against them.
RSpec.shared_context 'with an agent root' do
  include AgentRunner

  let(:root) { Dir.mktmpdir('file_transfer-root') }
  let(:config_dir) { Dir.mktmpdir('file_transfer-config') }
  let(:settings) { { 'tmpdir' => root } }
  let(:config) { write_config(config_dir, settings) }
  let(:uuid) { SecureRandom.uuid }

  after do
    FileUtils.remove_entry_secure(root)
    FileUtils.remove_entry_secure(config_dir)
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.order = :random
end
