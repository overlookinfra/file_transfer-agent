metadata :name        => "file_transfer",
         :description => "Chunked file transfer with SHA-256 verification",
         :author      => "Overlook InfraTech",
         :license     => "Apache-2.0",
         :version     => "1.0.0",
         :url         => "https://github.com/overlookinfra/file_transfer-agent",
         :provider    => "external",
         :timeout     => 120

action "cleanup", :description => "Remove a session directory that mktemp created" do
  display :always

  input :session,
        :prompt      => "Session",
        :description => "Session identifier, a lowercase UUID chosen by the caller",
        :type        => :string,
        :validation  => '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z',
        :maxlength   => 36,
        :optional    => false

  output :removed,
         :description => "Whether the session directory existed and was removed",
         :type        => "boolean",
         :display_as  => "Removed"
end

action "get", :description => "Read a chunk of a file as base64" do
  display :failed

  input :max_bytes,
        :prompt      => "Max Bytes",
        :description => "Maximum number of raw bytes to read",
        :type        => :integer,
        :optional    => false

  input :offset,
        :prompt      => "Offset",
        :description => "Byte offset to read from",
        :type        => :integer,
        :optional    => false

  input :path,
        :prompt      => "Path",
        :description => "Absolute path of the file to read",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => false

  output :bytes,
         :description => "Raw bytes in the chunk",
         :type        => "integer",
         :display_as  => "Bytes"

  output :data,
         :description => "The chunk, base64 encoded",
         :type        => "string",
         :display_as  => "Data"

  output :eof,
         :description => "Whether the chunk reaches the end of the file",
         :type        => "boolean",
         :display_as  => "EOF"

  output :size,
         :description => "File size in bytes at the time of the read",
         :type        => "integer",
         :display_as  => "Size"
end

action "list", :description => "List the entries of a directory in name order" do
  display :always

  input :limit,
        :prompt      => "Limit",
        :description => "Maximum number of entries to return",
        :type        => :integer,
        :default     => 1000,
        :optional    => true

  input :offset,
        :prompt      => "Offset",
        :description => "Number of entries to skip",
        :type        => :integer,
        :optional    => true

  input :path,
        :prompt      => "Path",
        :description => "Absolute path of the directory",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => false

  output :entries,
         :description => "Entries with name, type, symlink, size, mode, and mtime",
         :type        => "array",
         :display_as  => "Entries"

  output :total,
         :description => "Number of entries in the directory",
         :type        => "integer",
         :display_as  => "Total"
end

action "mkdir", :description => "Create a directory and any missing parents" do
  display :always

  input :mode,
        :prompt      => "Mode",
        :description => "Permission bits as octal digits for the directories this call creates",
        :type        => :string,
        :validation  => '\A[0-7]{3,4}\z',
        :maxlength   => 4,
        :optional    => true

  input :path,
        :prompt      => "Path",
        :description => "Absolute path of the directory",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => false
end

action "mktemp", :description => "Create a session directory under the agent's temp root and sweep stale sessions" do
  display :always

  input :session,
        :prompt      => "Session",
        :description => "Session identifier, a lowercase UUID chosen by the caller",
        :type        => :string,
        :validation  => '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z',
        :maxlength   => 36,
        :optional    => false

  output :path,
         :description => "Absolute path of the session directory",
         :type        => "string",
         :display_as  => "Path"

  output :swept,
         :description => "Number of stale session directories removed",
         :type        => "integer",
         :display_as  => "Swept"
end

action "put", :description => "Write a chunk of a file inside a session, verifying it and moving it to its destination on the final chunk" do
  display :failed

  input :data,
        :prompt      => "Data",
        :description => "The chunk, base64 encoded",
        :type        => :string,
        :validation  => '\A[A-Za-z0-9+/]*={0,2}\z',
        :maxlength   => 67108864,
        :optional    => false

  input :destination,
        :prompt      => "Destination",
        :description => "Absolute path to move the verified file to, with final",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => true

  input :final,
        :prompt      => "Final",
        :description => "Whether this is the last chunk of the file",
        :type        => :boolean,
        :optional    => true

  input :mode,
        :prompt      => "Mode",
        :description => "Permission bits as octal digits to apply to the verified file, with final",
        :type        => :string,
        :validation  => '\A[0-7]{3,4}\z',
        :maxlength   => 4,
        :optional    => true

  input :name,
        :prompt      => "Name",
        :description => "Path of the file relative to the session directory",
        :type        => :string,
        :validation  => '\A(\.{0,2}[^./\x5c\x00-\x1f\x7f][^/\x5c\x00-\x1f\x7f]*|\.\.[^/\x5c\x00-\x1f\x7f]+)(/(\.{0,2}[^./\x5c\x00-\x1f\x7f][^/\x5c\x00-\x1f\x7f]*|\.\.[^/\x5c\x00-\x1f\x7f]+))*\z',
        :maxlength   => 4096,
        :optional    => false

  input :offset,
        :prompt      => "Offset",
        :description => "Byte offset to write at, where 0 creates the file",
        :type        => :integer,
        :optional    => false

  input :session,
        :prompt      => "Session",
        :description => "Session identifier, a lowercase UUID chosen by the caller",
        :type        => :string,
        :validation  => '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z',
        :maxlength   => 36,
        :optional    => false

  input :sha256,
        :prompt      => "SHA-256",
        :description => "Expected SHA-256 hex digest of the whole file, required with final",
        :type        => :string,
        :validation  => '\A[0-9a-f]{64}\z',
        :maxlength   => 64,
        :optional    => true

  output :bytes,
         :description => "Raw bytes written by this call",
         :type        => "integer",
         :display_as  => "Bytes"

  output :sha256,
         :description => "SHA-256 hex digest computed on the final chunk",
         :type        => "string",
         :display_as  => "SHA-256"

  output :size,
         :description => "File size in bytes after the write",
         :type        => "integer",
         :display_as  => "Size"
end

action "stat", :description => "Report whether a path exists and describe it" do
  display :always

  input :checksum,
        :prompt      => "Checksum",
        :description => "Compute the SHA-256 of a regular file",
        :type        => :boolean,
        :optional    => true

  input :path,
        :prompt      => "Path",
        :description => "Absolute path on the node",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => false

  output :exists,
         :description => "Whether the path exists",
         :type        => "boolean",
         :display_as  => "Exists"

  output :mode,
         :description => "Permission bits as four octal digits",
         :type        => "string",
         :display_as  => "Mode"

  output :mtime,
         :description => "Modification time as Unix seconds",
         :type        => "integer",
         :display_as  => "Modified"

  output :sha256,
         :description => "SHA-256 hex digest when requested for a regular file",
         :type        => "string",
         :display_as  => "SHA-256"

  output :size,
         :description => "Size in bytes",
         :type        => "integer",
         :display_as  => "Size"

  output :symlink,
         :description => "Whether the path itself is a symbolic link",
         :type        => "boolean",
         :display_as  => "Symlink"

  output :type,
         :description => "file, directory, or other",
         :type        => "string",
         :display_as  => "Type"
end
