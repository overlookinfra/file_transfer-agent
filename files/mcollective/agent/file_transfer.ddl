metadata :name        => "file_transfer",
         :description => "Chunked file transfer with SHA-256 verification",
         :author      => "Overlook InfraTech",
         :license     => "Apache-2.0",
         :version     => "1.0.0",
         :url         => "https://github.com/overlookinfra/file_transfer-agent",
         :provider    => "external",
         :timeout     => 120

action "abort", :description => "Remove the temporary file of an upload that will not finish" do
  display :always

  input :destination,
        :prompt      => "Destination",
        :description => "Absolute path the upload was for, beside which its temporary file lives",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => false

  input :token,
        :prompt      => "Token",
        :description => "Token that names the temporary file, 16 lowercase hex characters chosen by the caller for one file",
        :type        => :string,
        :validation  => '\A[0-9a-f]{16}\z',
        :maxlength   => 16,
        :optional    => false

  output :removed,
         :description => "Whether the temporary file existed and was removed",
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

  output :size,
         :description => "File size in bytes at the time of the read",
         :type        => "integer",
         :display_as  => "Size"
end

action "list", :description => "List every entry under a directory" do
  display :always

  input :checksum,
        :prompt      => "Checksum",
        :description => "Compute the SHA-256 of every regular file",
        :type        => :boolean,
        :optional    => true

  input :max_bytes,
        :prompt      => "Max Bytes",
        :description => "Maximum size of the listing in bytes",
        :type        => :integer,
        :optional    => false

  input :path,
        :prompt      => "Path",
        :description => "Absolute path of the directory",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => false

  output :entries,
         :description => "Every entry under the directory, parents before their contents, with name relative to the directory, type, symlink, size, mode, and mtime, and with checksum the sha256 of each regular file, or null and an error for one the agent cannot read",
         :type        => "array",
         :display_as  => "Entries"
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

action "put", :description => "Write a chunk of a file under a temporary name beside its destination, verifying it and renaming it into place on the final chunk" do
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
        :description => "Absolute path the verified file is renamed to, beside which its chunks are assembled",
        :type        => :string,
        :validation  => '\A.+\z',
        :maxlength   => 4096,
        :optional    => false

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

  input :offset,
        :prompt      => "Offset",
        :description => "Byte offset to write at, where 0 creates the file",
        :type        => :integer,
        :optional    => false

  input :sha256,
        :prompt      => "SHA-256",
        :description => "Expected SHA-256 hex digest of the whole file, required with final",
        :type        => :string,
        :validation  => '\A[0-9a-f]{64}\z',
        :maxlength   => 64,
        :optional    => true

  input :token,
        :prompt      => "Token",
        :description => "Token that names the temporary file, 16 lowercase hex characters chosen by the caller for one file",
        :type        => :string,
        :validation  => '\A[0-9a-f]{16}\z',
        :maxlength   => 16,
        :optional    => false

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
         :description => "One of file, directory, or other",
         :type        => "string",
         :display_as  => "Type"
end
