# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer agent list action' do
  include_context 'with an agent root'

  # A directory to list that is not the session root itself, so the root's
  # own bookkeeping never shows up in the entries.
  let(:dir) { File.join(root, 'listing') }

  before { Dir.mkdir(dir) }

  def create_files(*names)
    names.each { |name| File.write(File.join(dir, name), '') }
  end

  def entry_names(reply)
    reply.data['entries'].map { |entry| entry['name'] }
  end

  it 'lists the entries of a directory in byte order of name' do
    create_files('b', '_under', 'A', 'a', '-dash', 'B')
    reply = run_agent('list', { path: dir })

    expect(reply.statuscode).to eq(0)
    expect(entry_names(reply)).to eq(['-dash', 'A', 'B', '_under', 'a', 'b'])
  end

  it 'answers a total equal to the number of entries in the directory' do
    create_files('one', 'two', 'three')
    Dir.mkdir(File.join(dir, 'sub'))
    reply = run_agent('list', { path: dir })

    expect(reply.data['total']).to eq(4)
    expect(reply.data['entries'].length).to eq(4)
  end

  it 'describes a regular file entry with its name, type, size, mode, and modification time' do
    path = File.join(dir, 'data.bin')
    File.write(path, 'hello world')
    File.chmod(0o640, path)
    File.utime(Time.at(1_700_000_000), Time.at(1_700_000_000), path)
    reply = run_agent('list', { path: dir })

    expect(reply.data['entries']).to eq([{ 'name' => 'data.bin', 'type' => 'file', 'symlink' => false,
                                           'size' => 11, 'mode' => '0640', 'mtime' => 1_700_000_000 }])
  end

  it 'describes a subdirectory entry with type directory and its own mode' do
    path = File.join(dir, 'sub')
    Dir.mkdir(path)
    File.chmod(0o750, path)
    File.utime(Time.at(1_700_000_500), Time.at(1_700_000_500), path)
    reply = run_agent('list', { path: dir })

    expect(reply.data['entries'].first).to include('name' => 'sub', 'type' => 'directory', 'symlink' => false,
      'mode' => '0750', 'mtime' => 1_700_000_500)
  end

  it 'reports a symbolic link to a file as a link whose type, size, and mode come from the target' do
    target = File.join(dir, 'target')
    File.write(target, 'abcde')
    File.chmod(0o604, target)
    File.symlink('target', File.join(dir, 'link'))
    reply = run_agent('list', { path: dir })

    link = reply.data['entries'].find { |entry| entry['name'] == 'link' }
    expect(link).to include('type' => 'file', 'symlink' => true, 'size' => 5, 'mode' => '0604')
  end

  it 'reports a symbolic link to a directory as a link with type directory' do
    Dir.mkdir(File.join(dir, 'sub'))
    File.symlink('sub', File.join(dir, 'link'))
    reply = run_agent('list', { path: dir })

    link = reply.data['entries'].find { |entry| entry['name'] == 'link' }
    expect(link).to include('type' => 'directory', 'symlink' => true)
  end

  it 'reports a dangling symbolic link as a link with type other' do
    File.symlink(File.join(dir, 'gone'), File.join(dir, 'dangling'))
    reply = run_agent('list', { path: dir })

    expect(reply.statuscode).to eq(0)
    expect(reply.data['entries']).to contain_exactly(include('name' => 'dangling', 'type' => 'other', 'symlink' => true))
  end

  it 'includes entries whose name starts with a dot' do
    create_files('.hidden', 'visible')
    reply = run_agent('list', { path: dir })

    expect(entry_names(reply)).to eq(['.hidden', 'visible'])
    expect(reply.data['total']).to eq(2)
  end

  it 'excludes the current and parent directory entries' do
    create_files('only')
    reply = run_agent('list', { path: dir })

    expect(entry_names(reply)).to eq(['only'])
    expect(reply.data['total']).to eq(1)
  end

  it 'skips the first offset entries' do
    create_files('a', 'b', 'c', 'd', 'e')
    reply = run_agent('list', { path: dir, offset: 2 })

    expect(entry_names(reply)).to eq(%w[c d e])
    expect(reply.data['total']).to eq(5)
  end

  it 'returns at most limit entries' do
    create_files('a', 'b', 'c', 'd', 'e')
    reply = run_agent('list', { path: dir, limit: 2 })

    expect(entry_names(reply)).to eq(%w[a b])
    expect(reply.data['total']).to eq(5)
  end

  it 'pages through the directory with offset and limit together' do
    create_files('a', 'b', 'c', 'd', 'e')
    reply = run_agent('list', { path: dir, offset: 3, limit: 2 })

    expect(entry_names(reply)).to eq(%w[d e])
    expect(reply.data['total']).to eq(5)
  end

  it 'answers no entries and the real total for an offset equal to the total' do
    create_files('a', 'b', 'c')
    reply = run_agent('list', { path: dir, offset: 3 })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('entries' => [], 'total' => 3)
  end

  it 'answers no entries and the real total for an offset beyond the total' do
    create_files('a', 'b', 'c')
    reply = run_agent('list', { path: dir, offset: 99 })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to include('entries' => [], 'total' => 3)
  end

  it 'returns 1000 entries when no limit is given' do
    1001.times { |index| File.write(File.join(dir, format('file-%04d', index)), '') }
    reply = run_agent('list', { path: dir })

    expect(reply.data['entries'].length).to eq(1000)
    expect(reply.data['total']).to eq(1001)
    expect(entry_names(reply).last).to eq('file-0999')
  end

  it 'caps a limit above 2000 at 2000 entries' do
    2001.times { |index| File.write(File.join(dir, format('file-%04d', index)), '') }
    reply = run_agent('list', { path: dir, limit: 5000 })

    expect(reply.data['entries'].length).to eq(2000)
    expect(reply.data['total']).to eq(2001)
    expect(entry_names(reply).last).to eq('file-1999')
  end

  it 'answers no entries but the total for a limit of zero' do
    create_files('a', 'b')
    reply = run_agent('list', { path: dir, limit: 0 })

    expect(reply.statuscode).to eq(0)
    expect(reply.data).to eq('entries' => [], 'total' => 2)
  end

  it 'rejects a negative limit' do
    create_files('a')
    reply = run_agent('list', { path: dir, limit: -1 })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The limit input must be at least 0')
  end

  it 'rejects a negative offset' do
    create_files('a')
    reply = run_agent('list', { path: dir, offset: -1 })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The offset input must be at least 0')
  end

  it 'rejects a relative path' do
    reply = run_agent('list', { path: 'listing' })

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The path input must be an absolute path')
  end

  it 'aborts when the path is a regular file' do
    path = File.join(dir, 'file.txt')
    File.write(path, 'x')
    reply = run_agent('list', { path: path })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('Not a directory').and include(path)
  end

  it 'aborts when the path does not exist' do
    path = File.join(dir, 'missing')
    reply = run_agent('list', { path: path })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('No such file or directory').and include(path)
  end

  it 'aborts when the directory cannot be read' do
    skip('needs a non-root user') if Process.euid.zero?

    File.chmod(0o000, dir)
    reply = run_agent('list', { path: dir })

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('Permission denied')
  end

  it 'answers no entries and a total of zero for an empty directory' do
    reply = run_agent('list', { path: dir })

    expect(reply.statuscode).to eq(0)
    expect(reply.statusmsg).to eq('OK')
    expect(reply.data).to eq('entries' => [], 'total' => 0)
  end

  it 'normalizes the path before listing it' do
    create_files('a')
    reply = run_agent('list', { path: File.join(dir, 'sub', '..') })

    expect(entry_names(reply)).to eq(['a'])
  end
end
