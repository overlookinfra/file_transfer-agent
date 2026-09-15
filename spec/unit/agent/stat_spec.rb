# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer agent stat action' do
  include_context 'with an agent root'

  let(:content) { 'a regular file the agent has to describe' }
  let(:mtime) { Time.at(1_600_000_000) }
  let(:file) { File.join(root, 'file.txt') }

  before do
    File.write(file, content)
    File.chmod(0o644, file)
    File.utime(mtime, mtime, file)
  end

  it 'describes a regular file' do
    reply = run_agent('stat', { path: file })

    expect(reply.statuscode).to eq(0)
    expect(reply.statusmsg).to eq('OK')
    expect(reply.data).to eq('exists' => true, 'type' => 'file', 'symlink' => false, 'size' => content.bytesize,
      'mode' => '0644', 'mtime' => mtime.to_i, 'sha256' => nil)
  end

  it 'reports a mode with a special bit as four octal digits' do
    File.chmod(0o4755, file)

    reply = run_agent('stat', { path: file })

    expect(reply.data['mode']).to eq('4755')
  end

  it 'answers the SHA-256 of a regular file when a checksum is asked for' do
    bytes = (0..255).to_a.pack('C*')
    binary = File.join(root, 'bytes.bin')
    File.binwrite(binary, bytes)

    reply = run_agent('stat', { path: binary, checksum: true })

    expect(reply.data).to include('type' => 'file', 'size' => bytes.bytesize, 'sha256' => sha256(bytes))
  end

  it 'answers the digest of no bytes at all for an empty file' do
    empty = File.join(root, 'empty.bin')
    File.write(empty, '')

    reply = run_agent('stat', { path: empty, checksum: true })

    expect(reply.data).to include('size' => 0, 'sha256' => sha256(''))
  end

  it 'describes a directory' do
    directory = File.join(root, 'tree')
    Dir.mkdir(directory)
    File.chmod(0o750, directory)
    File.utime(mtime, mtime, directory)

    reply = run_agent('stat', { path: directory })

    expect(reply.data).to match('exists' => true, 'type' => 'directory', 'symlink' => false, 'size' => be_positive,
      'mode' => '0750', 'mtime' => mtime.to_i, 'sha256' => nil)
  end

  it 'answers a null checksum for a directory' do
    directory = File.join(root, 'tree')
    Dir.mkdir(directory)

    reply = run_agent('stat', { path: directory, checksum: true })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('type' => 'directory', 'sha256' => nil)
  end

  it 'reports a fifo as type other' do
    fifo = File.join(root, 'pipe')
    File.mkfifo(fifo, 0o600)

    reply = run_agent('stat', { path: fifo })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('exists' => true, 'type' => 'other', 'symlink' => false, 'size' => 0, 'mode' => '0600')
  end

  it 'types a fifo as other and answers a null checksum without reading it' do
    fifo = File.join(root, 'pipe')
    File.mkfifo(fifo, 0o600)

    reply = run_agent('stat', { path: fifo, checksum: true })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('type' => 'other', 'sha256' => nil)
  end

  it 'describes the target of a symbolic link and marks the path as a link' do
    link = File.join(root, 'link.txt')
    File.symlink(file, link)

    reply = run_agent('stat', { path: link })

    expect(reply.data).to eq('exists' => true, 'type' => 'file', 'symlink' => true, 'size' => content.bytesize,
      'mode' => '0644', 'mtime' => mtime.to_i, 'sha256' => nil)
  end

  it 'checksums the target of a symbolic link to a file' do
    link = File.join(root, 'link.txt')
    File.symlink(file, link)

    reply = run_agent('stat', { path: link, checksum: true })

    expect(reply.data['sha256']).to eq(sha256(content))
  end

  it 'reports a dangling symbolic link as existing with type other' do
    link = File.join(root, 'dangling.txt')
    File.symlink(File.join(root, 'gone.txt'), link)

    reply = run_agent('stat', { path: link })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('exists' => true, 'symlink' => true, 'type' => 'other', 'sha256' => nil)
  end

  it 'answers exists false with every other field null for a missing path' do
    reply = run_agent('stat', { path: File.join(root, 'gone.txt') })

    expect(reply.statuscode).to eq(0)
    expect(reply.statusmsg).to eq('OK')
    expect(reply.data).to eq('exists' => false, 'type' => nil, 'symlink' => nil, 'size' => nil, 'mode' => nil,
      'mtime' => nil, 'sha256' => nil)
  end

  it 'answers exists false when the parent of the path is a regular file' do
    reply = run_agent('stat', { path: File.join(file, 'child.txt') })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('exists' => false, 'type' => nil, 'size' => nil)
  end

  it 'aborts with the operating system message when a parent directory denies access' do
    skip('needs a non-root user') if Process.euid.zero?

    closed = File.join(root, 'closed')
    Dir.mkdir(closed)
    hidden = File.join(closed, 'file.txt')
    File.write(hidden, content)
    File.chmod(0o000, closed)

    begin
      reply = run_agent('stat', { path: hidden })

      expect(reply.statuscode).to eq(1)
      expect(reply.statusmsg).to include('Permission denied')
    ensure
      File.chmod(0o700, closed)
    end
  end

  it 'refuses a relative path' do
    reply = run_agent('stat', { path: 'file.txt' })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The path input must be an absolute path')
    expect(reply.data).to be_empty
    expect(reply.stdout).to be_empty
  end

  it 'refuses a path with a NUL byte' do
    # 0.chr is the NUL, spelled this way so the byte is visible in review.
    with_nul = "#{file}#{0.chr}.txt"

    reply = run_agent('stat', { path: with_nul })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The path input must be an absolute path')
    expect(reply.stdout).to be_empty
  end

  it 'refuses an empty path' do
    reply = run_agent('stat', { path: '' })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The path input must be an absolute path')
    expect(reply.stdout).to be_empty
  end

  it 'normalizes parent references in the path before describing it' do
    reply = run_agent('stat', { path: "/etc/..#{file}" })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('exists' => true, 'type' => 'file', 'size' => content.bytesize)
  end
end
