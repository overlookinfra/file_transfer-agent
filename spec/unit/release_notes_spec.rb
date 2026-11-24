# frozen_string_literal: true

require 'spec_helper'
require_relative '../../rakelib/lib/release_notes'

RSpec.describe ReleaseNotes do
  let(:changelog) do
    <<~'CHANGELOG'
      # Changelog

      All notable changes to this project will be documented in this file.

      ## [1.2.0](https://github.com/overlookinfra/file_transfer-agent/tree/1.2.0) (2026-12-01)

      [Full Changelog](https://github.com/overlookinfra/file_transfer-agent/compare/1.1.0...1.2.0)

      **Implemented enhancements:**

      - Add the cleanup action [\#7](https://github.com/overlookinfra/file_transfer-agent/pull/7) ([octocat](https://github.com/octocat))

      **Fixed bugs:**

      - Stop the helper at the deadline [\#6](https://github.com/overlookinfra/file_transfer-agent/pull/6) ([octocat](https://github.com/octocat))

      ## [1.1.0](https://github.com/overlookinfra/file_transfer-agent/tree/1.1.0) (2026-11-01)

      [Full Changelog](https://github.com/overlookinfra/file_transfer-agent/compare/1.0.0...1.1.0)

      **Merged pull requests:**

      - Add the status action [\#3](https://github.com/overlookinfra/file_transfer-agent/pull/3) ([octocat](https://github.com/octocat))
    CHANGELOG
  end

  it 'returns the section of a version between 2 headings with its sub-headings and list items' do
    expect(described_class.extract(changelog, '1.2.0')).to eq(<<~'NOTES'.chomp)
      [Full Changelog](https://github.com/overlookinfra/file_transfer-agent/compare/1.1.0...1.2.0)

      **Implemented enhancements:**

      - Add the cleanup action [\#7](https://github.com/overlookinfra/file_transfer-agent/pull/7) ([octocat](https://github.com/octocat))

      **Fixed bugs:**

      - Stop the helper at the deadline [\#6](https://github.com/overlookinfra/file_transfer-agent/pull/6) ([octocat](https://github.com/octocat))
    NOTES
  end

  it 'returns the last section up to the end of the text' do
    expect(described_class.extract(changelog, '1.1.0')).to eq(<<~'NOTES'.chomp)
      [Full Changelog](https://github.com/overlookinfra/file_transfer-agent/compare/1.0.0...1.1.0)

      **Merged pull requests:**

      - Add the status action [\#3](https://github.com/overlookinfra/file_transfer-agent/pull/3) ([octocat](https://github.com/octocat))
    NOTES
  end

  it 'returns nil for a version without a heading' do
    expect(described_class.extract(changelog, '2.0.0')).to be_nil
  end

  it 'returns nil when another heading only starts with the characters of the version' do
    candidate = "## [1.2.0-rc1](https://github.com/overlookinfra/file_transfer-agent/tree/1.2.0-rc1) (2026-11-20)\n\n- Add the cleanup action\n"

    expect(described_class.extract(candidate, '1.2.0')).to be_nil
  end

  it 'returns nil for a blank section between 2 headings and at the end of the text' do
    blank = "## [1.2.0](https://example.com/1.2.0) (2026-12-01)\n\n \n## [1.1.0](https://example.com/1.1.0) (2026-11-01)\n\n- Add the status action\n"
    blank_last = "## [1.1.0](https://example.com/1.1.0) (2026-11-01)\n\n  \n"

    expect(described_class.extract(blank, '1.2.0')).to be_nil
    expect(described_class.extract(blank_last, '1.1.0')).to be_nil
  end
end
