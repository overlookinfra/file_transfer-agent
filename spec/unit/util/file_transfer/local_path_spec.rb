# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MCollective::Util::FileTransfer::LocalPath do
  describe '.plain_name?' do
    it 'accepts a name that is one path component' do
      expect(described_class.plain_name?('app.log')).to be(true)
    end

    {
      'nil' => nil,
      'an empty string' => '',
      'one dot' => '.',
      'two dots' => '..',
      'a name with a slash' => 'a/b',
      'a name with a backslash' => 'back\\slash',
      'a name with a newline' => "a\nb",
      'a name with a carriage return, as macOS names a folder icon' => "Icon\r",
      'a name with a C1 control character, which the agent refuses too' => "Don\u0092t.txt",
      'a name that is not valid in its encoding' => JSON.parse('["a\\udcffb"]').first,
    }.each do |description, name|
      it "refuses #{description}" do
        expect(described_class.plain_name?(name)).to be(false)
      end
    end

    context 'when the client runs on Windows' do
      before { allow(Gem).to receive(:win_platform?).and_return(true) }

      it 'accepts a name that is one path component there too' do
        expect(described_class.plain_name?('app.log')).to be(true)
      end

      ['CONFIG.txt', 'LPT10'].each do |name|
        it "accepts #{name.inspect}, which only begins like a device name" do
          expect(described_class.plain_name?(name)).to be(true)
        end
      end

      {
        'a device name' => 'CON',
        'a device name in another case with an extension' => 'nul.txt',
        'a numbered device name' => 'COM1',
        'a name with a colon' => 'c:d',
        'a name ending with a dot' => 'name.',
        'a name ending with a space' => 'name ',
      }.each do |description, name|
        it "refuses #{description}" do
          expect(described_class.plain_name?(name)).to be(false)
        end
      end
    end

    context 'when the client runs elsewhere' do
      before { allow(Gem).to receive(:win_platform?).and_return(false) }

      ['CON.txt', 'name.'].each do |name|
        it "accepts #{name.inspect}, which only Windows refuses" do
          expect(described_class.plain_name?(name)).to be(true)
        end
      end
    end
  end

  describe '.plain_relative_path?' do
    ['app.log', 'logs/app.log', 'a/b/c'].each do |path|
      it "accepts #{path.inspect}" do
        expect(described_class.plain_relative_path?(path)).to be(true)
      end
    end

    {
      'nil' => nil,
      'an empty path' => '',
      'an absolute path, whose first component is empty' => '/etc/passwd',
      'a path with a parent component' => 'a/../b',
      'a path with a backslash' => 'a\\b/c',
      'a path with a control character' => "a/b\nc",
      'a path that is not valid in its encoding' => JSON.parse('["a/\\udcffb"]').first,
    }.each do |description, path|
      it "refuses #{description}" do
        expect(described_class.plain_relative_path?(path)).to be(false)
      end
    end
  end

  describe '.last_component' do
    {
      'a POSIX path' => ['/var/log/app.log', 'app.log'],
      'a POSIX path whose name holds a backslash' => ['/srv/back\\slash.txt', 'back\\slash.txt'],
      'a Windows path' => ['C:\\logs\\app.log', 'app.log'],
      'a path that ends in a separator' => ['/var/log/', 'log'],
      'a bare name' => ['app.log', 'app.log'],
    }.each do |description, (path, component)|
      it "takes the last component of #{description}" do
        expect(described_class.last_component(path)).to eq(component)
      end
    end

    it 'is empty for a root, which is no plain name' do
      expect(described_class.last_component('/')).to eq('')
      expect(described_class.plain_name?(described_class.last_component('/'))).to be(false)
    end
  end

  describe '.names_directory?' do
    {
      'a POSIX path that ends in a slash' => ['/opt/app/', true],
      'a POSIX path' => ['/opt/app', false],
      'a POSIX path whose name ends in a backslash' => ['/opt/app\\', false],
      'a Windows path that ends in a backslash' => ['C:\\app\\', true],
    }.each do |description, (path, answer)|
      it "is #{answer} for #{description}" do
        expect(described_class.names_directory?(path)).to be(answer)
      end
    end
  end

  describe '.as_utf8' do
    it 'reads a path tagged as plain bytes as UTF-8' do
      path = described_class.as_utf8('/var/log/café.log'.b)

      expect(path.encoding).to eq(Encoding::UTF_8)
      expect(path).to eq('/var/log/café.log')
    end

    it 'reads a path tagged US-ASCII as UTF-8' do
      expect(described_class.as_utf8('/var/log/app.log'.encode(Encoding::US_ASCII)).encoding).to eq(Encoding::UTF_8)
    end

    it 'leaves a path tagged UTF-8 as it is' do
      path = described_class.as_utf8('/var/log/café.log')

      expect(path.encoding).to eq(Encoding::UTF_8)
      expect(path).to eq('/var/log/café.log')
    end
  end
end
