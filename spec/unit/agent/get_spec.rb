# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer agent get action' do
  include_context 'with an agent root'

  # Ten distinct ten byte runs, so a chunk read from the wrong offset cannot
  # look like the right one.
  let(:content) { ('a'..'j').map { |letter| letter * 10 }.join }
  let(:work) { Dir.mktmpdir('file_transfer-work') }
  let(:source) do
    path = File.join(work, 'source.txt')
    File.binwrite(path, content)
    path
  end

  after { FileUtils.remove_entry_secure(work) }

  it 'reads the whole file when max_bytes covers it' do
    reply = run_agent('get', { path: source, offset: 0, max_bytes: 1000 })

    expect(reply.statuscode).to eq(0)
    expect(reply.statusmsg).to eq('OK')
    expect(decoded(reply)).to eq(content)
    expect(reply.data).to include('bytes' => 100, 'eof' => true, 'size' => 100)
  end

  it 'reads max_bytes from the start of the file' do
    reply = run_agent('get', { path: source, offset: 0, max_bytes: 10 })

    expect(decoded(reply)).to eq('a' * 10)
    expect(reply.data).to include('bytes' => 10, 'eof' => false, 'size' => 100)
  end

  it 'answers the file for a max_bytes far beyond anything a reply could carry' do
    reply = run_agent('get', { path: source, offset: 0, max_bytes: 2**62 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq(content)
    expect(reply.data).to include('bytes' => 100, 'eof' => true)
  end

  it 'reads max_bytes from the offset it is given' do
    reply = run_agent('get', { path: source, offset: 40, max_bytes: 10 })

    expect(decoded(reply)).to eq('e' * 10)
    expect(reply.data).to include('bytes' => 10, 'eof' => false, 'size' => 100)
  end

  it 'reports eof true for the chunk that ends exactly at the end of the file' do
    reply = run_agent('get', { path: source, offset: 90, max_bytes: 10 })

    expect(decoded(reply)).to eq('j' * 10)
    expect(reply.data).to include('bytes' => 10, 'eof' => true, 'size' => 100)
  end

  it 'answers only the bytes that remain when max_bytes runs past the end of the file' do
    reply = run_agent('get', { path: source, offset: 90, max_bytes: 1000 })

    expect(decoded(reply)).to eq('j' * 10)
    expect(reply.data).to include('bytes' => 10, 'eof' => true, 'size' => 100)
  end

  it 'answers zero bytes and eof true for an offset at the end of the file' do
    reply = run_agent('get', { path: source, offset: 100, max_bytes: 10 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq('')
    expect(reply.data).to include('bytes' => 0, 'eof' => true, 'size' => 100)
  end

  it 'answers zero bytes and eof true for an offset past the end of the file' do
    reply = run_agent('get', { path: source, offset: 500, max_bytes: 10 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq('')
    expect(reply.data).to include('bytes' => 0, 'eof' => true, 'size' => 100)
  end

  it 'answers zero bytes with eof false for max_bytes 0 before the end of the file' do
    reply = run_agent('get', { path: source, offset: 0, max_bytes: 0 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq('')
    expect(reply.data).to include('bytes' => 0, 'eof' => false, 'size' => 100)
  end

  it 'answers zero bytes with eof true for max_bytes 0 at the end of the file' do
    reply = run_agent('get', { path: source, offset: 100, max_bytes: 0 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq('')
    expect(reply.data).to include('bytes' => 0, 'eof' => true, 'size' => 100)
  end

  it 'answers zero bytes and eof true for an empty file' do
    path = File.join(work, 'empty.bin')
    File.binwrite(path, '')

    reply = run_agent('get', { path: path, offset: 0, max_bytes: 1000 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq('')
    expect(reply.data).to include('bytes' => 0, 'eof' => true, 'size' => 0)
  end

  it 'round trips content that holds every byte value' do
    path = File.join(work, 'bytes.bin')
    every_byte = (0..255).to_a.pack('C*')
    File.binwrite(path, every_byte)

    reply = run_agent('get', { path: path, offset: 0, max_bytes: 1000 })

    expect(decoded(reply)).to eq(every_byte)
    expect(reply.data).to include('bytes' => 256, 'eof' => true, 'size' => 256)
  end

  it 'reports eof false for a chunk that does not reach the end of the file' do
    path = File.join(work, 'repetitive.bin')
    File.binwrite(path, 'A' * 5000)

    reply = run_agent('get', { path: path, offset: 1000, max_bytes: 1000 })

    expect(reply.data).to include('bytes' => 1000, 'eof' => false, 'size' => 5000)
    expect(decoded(reply)).to eq('A' * 1000)
  end

  it 'follows a symbolic link to a file' do
    link = File.join(work, 'link.txt')
    File.symlink(source, link)

    reply = run_agent('get', { path: link, offset: 0, max_bytes: 1000 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq(content)
    expect(reply.data).to include('bytes' => 100, 'eof' => true, 'size' => 100)
  end

  it 'folds a parent reference in the path before reading' do
    # expand_path is lexical, so the component that does not exist never reaches the filesystem.
    path = File.join(File.dirname(source), 'no-such-dir', '..', File.basename(source))

    reply = run_agent('get', { path: path, offset: 0, max_bytes: 1000 })

    expect(reply.statuscode).to eq(0)
    expect(decoded(reply)).to eq(content)
  end

  it 'leaves the file it reads untouched' do
    mtime = File.stat(source).mtime
    mode = mode_of(source)

    run_agent('get', { path: source, offset: 40, max_bytes: 10 })

    expect(File.binread(source)).to eq(content)
    expect(File.stat(source).mtime).to eq(mtime)
    expect(mode_of(source)).to eq(mode)
  end

  it 'aborts when the path is a directory' do
    directory = File.join(work, 'subdir')
    Dir.mkdir(directory)

    reply = run_agent('get', { path: directory, offset: 0, max_bytes: 10 })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include(directory, 'is not a regular file')
    expect(reply.data).to eq({})
  end

  it 'aborts quietly and exits zero when the path does not exist, so the server reads the reply file' do
    missing = File.join(work, 'missing.txt')

    reply = run_agent('get', { path: missing, offset: 0, max_bytes: 10 })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('No such file or directory', missing)
    expect(reply.data).to eq({})
    expect(reply.exitstatus).to eq(0)
    expect(reply.stdout).to be_empty
    expect(reply.stderr).to be_empty
  end

  it 'aborts at once for a fifo instead of blocking on it' do
    fifo = File.join(work, 'pipe')
    File.mkfifo(fifo, 0o600)

    reply = Timeout.timeout(10) { run_agent('get', { path: fifo, offset: 0, max_bytes: 10 }) }

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include(fifo, 'is not a regular file')
  end

  it 'aborts when the file cannot be read' do
    skip('needs a non-root user') if Process.euid.zero?

    File.chmod(0o000, source)

    reply = run_agent('get', { path: source, offset: 0, max_bytes: 10 })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('Permission denied', source)
  end

  it 'rejects a relative path as invalid data' do
    reply = run_agent('get', { path: 'source.txt', offset: 0, max_bytes: 10 })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The path input must be an absolute path')
    expect(reply.data).to eq({})
  end

  it 'rejects a negative offset as invalid data' do
    reply = run_agent('get', { path: source, offset: -1, max_bytes: 10 })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The offset input must be at least 0')
  end

  it 'rejects a negative max_bytes as invalid data' do
    reply = run_agent('get', { path: source, offset: 0, max_bytes: -1 })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The max_bytes input must be at least 0')
  end

  it 'answers missing data when max_bytes is absent' do
    reply = run_agent('get', { path: source, offset: 0 })

    expect(reply.statuscode).to eq(3)
    expect(reply.statusmsg).to include('The max_bytes input is required')
  end

  it 'answers missing data when offset is absent' do
    reply = run_agent('get', { path: source, max_bytes: 10 })

    expect(reply.statuscode).to eq(3)
    expect(reply.statusmsg).to include('The offset input is required')
  end

  it 'answers missing data when path is absent' do
    reply = run_agent('get', { offset: 0, max_bytes: 10 })

    expect(reply.statuscode).to eq(3)
    expect(reply.statusmsg).to include('The path input is required')
  end
end
