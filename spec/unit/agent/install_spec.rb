# frozen_string_literal: true

require 'spec_helper'

# The Choria server runs the agent file directly, so what the harness
# bypasses by naming the interpreter has to hold for the committed file.
RSpec.describe 'the file_transfer agent file' do
  it 'is executable' do
    expect(File.stat(AGENT).mode & 0o111).to eq(0o111)
  end

  it 'starts with an absolute shebang naming the Ruby that Puppet ships' do
    expect(File.new(AGENT).readline.chomp).to eq('#!/opt/puppetlabs/puppet/bin/ruby')
  end
end
