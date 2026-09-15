# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer agent mkdir action' do
  include_context 'with an agent root'

  it 'creates every missing directory of a nested path without a mode and answers created true' do
    target = File.join(root, 'a', 'b', 'c')

    reply = run_agent('mkdir', { 'path' => target })

    expect(reply.statuscode).to eq(0)
    expect(reply.statusmsg).to eq('OK')
    expect(reply.data).to eq('created' => true)
    expect(File.directory?(File.join(root, 'a'))).to be(true)
    expect(File.directory?(File.join(root, 'a', 'b'))).to be(true)
    expect(File.directory?(target)).to be(true)
    expect(reply.stderr).to be_empty
  end

  it 'applies the given mode to every directory it creates' do
    target = File.join(root, 'a', 'b', 'c')

    reply = run_agent('mkdir', { 'path' => target, 'mode' => '0750' })

    expect(reply.statuscode).to eq(0)
    created = [File.join(root, 'a'), File.join(root, 'a', 'b'), target]
    expect(created.map { |directory| mode_of(directory) }).to eq(%w[0750 0750 0750])
  end

  it 'applies the given mode even where the umask would narrow it' do
    target = File.join(root, 'shared')
    previous_umask = File.umask(0o077)
    begin
      reply = run_agent('mkdir', { 'path' => target, 'mode' => '0755' })
    ensure
      File.umask(previous_umask)
    end

    expect(reply.statuscode).to eq(0)
    expect(mode_of(target)).to eq('0755')
  end

  it 'keeps the mode of an ancestor that already existed' do
    ancestor = File.join(root, 'ancestor')
    Dir.mkdir(ancestor)
    File.chmod(0o755, ancestor)

    reply = run_agent('mkdir', { 'path' => File.join(ancestor, 'child'), 'mode' => '0750' })

    expect(reply.statuscode).to eq(0)
    expect(mode_of(ancestor)).to eq('0755')
    expect(mode_of(File.join(ancestor, 'child'))).to eq('0750')
  end

  it 'answers created false for a directory that already exists' do
    target = File.join(root, 'already')
    Dir.mkdir(target)

    reply = run_agent('mkdir', { 'path' => target })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to eq('created' => false)
    expect(File.directory?(target)).to be(true)
  end

  it 'leaves the mode of an existing directory alone when a mode is given' do
    target = File.join(root, 'already')
    Dir.mkdir(target)
    File.chmod(0o755, target)

    reply = run_agent('mkdir', { 'path' => target, 'mode' => '0700' })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to eq('created' => false)
    expect(mode_of(target)).to eq('0755')
  end

  it 'refuses a path where a regular file already exists' do
    target = File.join(root, 'occupied')
    File.write(target, 'contents')

    reply = run_agent('mkdir', { 'path' => target })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include("#{target} exists and is not a directory")
    expect(reply.data).to be_empty
    expect(File.file?(target)).to be(true)
    expect(File.binread(target)).to eq('contents')
    expect(reply.stdout).to be_empty
    expect(reply.exitstatus).to eq(0)
  end

  it 'refuses a path whose ancestor is a regular file and creates nothing' do
    ancestor = File.join(root, 'ancestor')
    File.write(ancestor, 'contents')

    reply = run_agent('mkdir', { 'path' => File.join(ancestor, 'child', 'leaf') })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include("#{ancestor} exists and is not a directory")
    expect(File.file?(ancestor)).to be(true)
    expect(File.binread(ancestor)).to eq('contents')
    expect(Dir.children(root)).to eq(['ancestor'])
    expect(reply.stdout).to be_empty
  end

  it 'creates the directory inside the target of a symbolic link used as an ancestor' do
    target = File.join(root, 'target')
    Dir.mkdir(target)
    link = File.join(root, 'link')
    File.symlink(target, link)

    reply = run_agent('mkdir', { 'path' => File.join(link, 'made'), 'mode' => '0750' })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to eq('created' => true)
    expect(File.directory?(File.join(target, 'made'))).to be(true)
    expect(mode_of(File.join(target, 'made'))).to eq('0750')
    expect(File.symlink?(link)).to be(true)
  end

  it 'refuses a relative path and creates nothing in its working directory' do
    reply = run_agent('mkdir', { 'path' => "#{uuid}/dir" })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The path input must be an absolute path')
    expect(reply.data).to be_empty
    expect(File.exist?(File.join(Dir.tmpdir, uuid))).to be(false)
    expect(reply.stdout).to be_empty
    expect(reply.exitstatus).to eq(0)
  end

  { '0999' => 'a digit above seven', 'rwx' => 'letters', 493 => 'an integer' }.each do |mode, description|
    it "refuses a mode given as #{description} and creates nothing" do
      target = File.join(root, 'unmade')

      reply = run_agent('mkdir', { 'path' => target, 'mode' => mode })

      expect(reply.statuscode).to eq(4)
      expect(reply.statusmsg).to include('The mode input must be three or four octal digits')
      expect(File.exist?(target)).to be(false)
      expect(Dir.children(root)).to be_empty
      expect(reply.stdout).to be_empty
    end
  end

  it 'applies setgid and setuid bits from a four-digit mode, which the kernel drops at creation' do
    target = File.join(root, 'shared', 'setuid')

    reply = run_agent('mkdir', { 'path' => target, 'mode' => '6775' })

    expect(reply.statuscode).to eq(0)
    expect(mode_of(File.join(root, 'shared'))).to eq('6775')
    expect(mode_of(target)).to eq('6775')
  end

  it 'normalizes the path before creating it' do
    normalized = File.join(root, 'two', 'leaf')

    reply = run_agent('mkdir', { 'path' => File.join(root, 'one', '..', 'two', '.', 'leaf') })

    expect(reply.statuscode).to eq(0)
    expect(File.directory?(normalized)).to be(true)
    expect(File.exist?(File.join(root, 'one'))).to be(false)
  end

  it 'refuses a path under a parent the agent may not write' do
    skip('needs a non-root user') if Process.euid.zero?

    parent = File.join(root, 'readonly')
    Dir.mkdir(parent)
    File.chmod(0o500, parent)

    reply = run_agent('mkdir', { 'path' => File.join(parent, 'child') })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to match(/Permission denied/)
    expect(File.exist?(File.join(parent, 'child'))).to be(false)
  end
end
