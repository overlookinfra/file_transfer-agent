# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'the file_transfer agent list action' do
  include_context 'with an agent root'

  let(:dir) { File.join(root, 'listing') }

  before { Dir.mkdir(dir) }

  def create_files(*names)
    names.each { |name| File.write(File.join(dir, name), '') }
  end

  # A list request with room for every listing these examples make, unless
  # an example says otherwise.
  def list(path, max_bytes: 100_000)
    run_agent('list', { path: path, max_bytes: max_bytes })
  end

  def entry_names(reply)
    reply.data['entries'].map { |entry| entry['name'] }
  end

  it 'lists the entries of a directory in byte order of name, dot files included' do
    create_files('b', '_under', 'A', 'a', '-dash', 'B', '.hidden')
    reply = list(dir)

    expect(reply.statuscode).to eq(0)
    expect(entry_names(reply)).to eq(['-dash', '.hidden', 'A', 'B', '_under', 'a', 'b'])
  end

  it 'lists every entry under the directory with its path relative to it, parents before their contents' do
    FileUtils.mkdir_p(File.join(dir, 'sub', 'deeper'))
    create_files('top.txt')
    File.write(File.join(dir, 'sub', 'inner.txt'), '')
    File.write(File.join(dir, 'sub', 'deeper', 'last.txt'), '')
    reply = list(dir)

    expect(reply.statuscode).to eq(0)
    expect(entry_names(reply)).to eq(['sub', 'sub/deeper', 'sub/deeper/last.txt', 'sub/inner.txt', 'top.txt'])
  end

  it 'lists a symbolic link to a directory without entering it' do
    Dir.mkdir(File.join(dir, 'real'))
    File.write(File.join(dir, 'real', 'inner.txt'), '')
    File.symlink(File.join(dir, 'real'), File.join(dir, 'link'))
    reply = list(dir)

    expect(entry_names(reply)).to eq(['link', 'real', 'real/inner.txt'])
    expect(reply.data['entries'].first).to include('name' => 'link', 'type' => 'directory', 'symlink' => true)
  end

  it 'lists through a symbolic link given as the directory' do
    create_files('a')
    link = File.join(root, 'link-to-listing')
    File.symlink(dir, link)
    reply = list(link)

    expect(entry_names(reply)).to eq(['a'])
  end

  it 'aborts when the listing does not fit in max_bytes' do
    create_files('a.txt', 'b.txt', 'c.txt')
    reply = list(dir, max_bytes: 100)

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include("The listing of #{dir} does not fit in 100 bytes", 'take its subdirectories one at a time')
  end

  it 'weighs an entry as the reply carries it, with a quote or a backslash at four bytes, so its JSON size alone does not fit' do
    create_files('a.txt')
    raw = JSON.generate(list(dir).data['entries'].first).bytesize

    refused = list(dir, max_bytes: raw)
    listed = list(dir, max_bytes: raw * 2)

    expect(refused.statuscode).to eq(1)
    expect(refused.statusmsg).to include("does not fit in #{raw} bytes")
    expect(listed.statuscode).to eq(0)
    expect(entry_names(listed)).to eq(['a.txt'])
  end

  it 'rejects a negative max_bytes' do
    reply = list(dir, max_bytes: -1)

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The max_bytes input must be at least 0')
  end

  it 'describes a regular file entry with its name, type, size, mode, and modification time' do
    path = File.join(dir, 'data.bin')
    File.write(path, 'hello world')
    File.chmod(0o640, path)
    File.utime(Time.at(1_700_000_000), Time.at(1_700_000_000), path)
    reply = list(dir)

    expect(reply.data['entries']).to eq([{ 'name' => 'data.bin', 'type' => 'file', 'symlink' => false,
                                           'size' => 11, 'mode' => '0640', 'mtime' => 1_700_000_000 }])
  end

  it 'describes a subdirectory entry with type directory and its own mode' do
    path = File.join(dir, 'sub')
    Dir.mkdir(path)
    File.chmod(0o750, path)
    File.utime(Time.at(1_700_000_500), Time.at(1_700_000_500), path)
    reply = list(dir)

    expect(reply.data['entries'].first).to include('name' => 'sub', 'type' => 'directory', 'symlink' => false,
      'mode' => '0750', 'mtime' => 1_700_000_500)
  end

  it 'reports a symbolic link to a file as a link whose type, size, and mode come from the target' do
    target = File.join(dir, 'target')
    File.write(target, 'abcde')
    File.chmod(0o604, target)
    File.symlink('target', File.join(dir, 'link'))
    reply = list(dir)

    link = reply.data['entries'].find { |entry| entry['name'] == 'link' }
    expect(link).to include('type' => 'file', 'symlink' => true, 'size' => 5, 'mode' => '0604')
  end

  it 'reports a dangling symbolic link as a link with type other' do
    File.symlink(File.join(dir, 'gone'), File.join(dir, 'dangling'))
    reply = list(dir)

    expect(reply.statuscode).to eq(0)
    expect(reply.data['entries']).to contain_exactly(include('name' => 'dangling', 'type' => 'other', 'symlink' => true))
  end

  it 'reports a symbolic link that points at itself as a link with type other and lists the rest' do
    File.symlink(File.join(dir, 'loop'), File.join(dir, 'loop'))
    create_files('plain.txt')
    reply = list(dir)

    expect(reply.statuscode).to eq(0)
    expect(reply.data['entries']).to contain_exactly(include('name' => 'loop', 'type' => 'other', 'symlink' => true),
      include('name' => 'plain.txt', 'type' => 'file', 'symlink' => false))
  end

  it 'lists names with letters outside ASCII, from the directory and from the subdirectory itself' do
    Dir.mkdir(File.join(dir, 'café'))
    File.write(File.join(dir, 'café', 'naïve.txt'), '')

    expect(entry_names(list(dir))).to eq(['café', 'café/naïve.txt'])
    expect(entry_names(list(File.join(dir, 'café')))).to eq(['naïve.txt'])
  end

  it 'rejects a relative path' do
    reply = list('listing')

    expect(reply.statuscode).to eq(4)
    expect(reply.statusmsg).to include('The path input must be an absolute path')
  end

  it 'aborts when the path is a regular file' do
    path = File.join(dir, 'file.txt')
    File.write(path, 'x')
    reply = list(path)

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('Not a directory').and include(path)
  end

  it 'aborts when the path does not exist' do
    path = File.join(dir, 'missing')
    reply = list(path)

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('No such file or directory').and include(path)
  end

  it 'aborts when the directory cannot be read' do
    skip('needs a non-root user') if Process.euid.zero?

    File.chmod(0o000, dir)
    reply = list(dir)

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include('Permission denied')
  end

  it 'answers no entries for an empty directory' do
    reply = list(dir)

    expect(reply.statuscode).to eq(0)
    expect(reply.statusmsg).to eq('OK')
    expect(reply.data).to eq('entries' => [])
  end

  it 'normalizes the path before listing it' do
    create_files('a')
    reply = list(File.join(dir, 'sub', '..'))

    expect(entry_names(reply)).to eq(['a'])
  end

  it 'aborts for an entry whose name is not valid UTF-8 and names it' do
    begin
      File.write(File.join(dir, "caf\xE9.txt".b), '')
    rescue SystemCallError
      skip('needs a filesystem that accepts a name that is not valid UTF-8')
    end
    create_files('ok.txt')

    reply = list(dir)

    expect(reply.statuscode).to eq(1)
    expect(reply.statusmsg).to include("#{dir} holds an entry whose name is not valid UTF-8", 'caf')
  end
end
