# file_transfer agent

A Choria external agent that moves files to and from nodes in chunks over
standard Choria RPC, with whole-file SHA-256 verification. Any Choria client
can use it to put files on nodes or fetch files from them. It was designed
for OpenBolt's Choria transport, but nothing in it is specific to OpenBolt.

Every chunk is a signed, base64-encoded RPC round trip, so transfers through
Choria are far less efficient than a download from a file server. The agent
is meant for smaller files. Gigabytes belong on a file server.

## Installation

The module is a Puppet module that depends on `choria/mcollective`. Put it
in the Puppet environment under the directory name
`mcollective_agent_file_transfer`, either with a Puppetfile entry from its
Git repository:

```
mod 'mcollective_agent_file_transfer',
  git: 'https://github.com/overlookinfra/file_transfer-agent',
  ref: 'main'
```

or with a clone of the repository into the environment's modules directory
under that name:

```
git clone https://github.com/overlookinfra/file_transfer-agent mcollective_agent_file_transfer
```

Puppet only sees module directories whose names are lowercase letters,
digits, and underscores, so a clone under the repository's own name is
ignored and the class is not found. Then add the class to the plugins the
Choria module installs:

```yaml
mcollective::plugin_classes:
  - mcollective_agent_file_transfer
```

The Choria module contains every class in that list, and this one installs
the agent, its DDL files, and its policy file where `mcollective::server`
is true, and the client library where `mcollective::client` is true,
through `mcollective::module_plugin`. The Choria module sets
`mcollective::client` to false by default, so the host that runs OpenBolt
needs it set to true, or `mcollective_agent_file_transfer::client: true`
for this module alone. The files are installed under `mcollective/` in the
Choria libdir, `/opt/puppetlabs/mcollective/plugins` by default. The
Choria server picks up the agent without a restart. Without Puppet, the
files listed in `data/plugin.yaml` go under `mcollective/` in the Choria
libdir of a server or a client. The agent reads no settings, so
`mcollective_agent_file_transfer::server_config` needs no keys.

### Requirements

The agent and the client library need Ruby 3.2 or later, and use nothing
that Ruby 4.0 removed or moved out of its default gems. The agent runs on
Linux, macOS, and Windows nodes under the Puppet agent's Ruby and loads
only the standard library. On POSIX nodes the server runs the script
through its shebang, `/opt/puppetlabs/puppet/bin/ruby --disable-gems`,
which skips rubygems, most of a Ruby start. On Windows the server resolves
the agent's name through `PATHEXT`, so the module installs
`file_transfer.bat` beside the script, which runs it with the Puppet
agent's `ruby.exe` at its default path and the same flag. There the last
component of a destination may not contain a colon, a reserved device name
such as `CON` or `COM1`, or a trailing dot or space, since Windows would
put the file somewhere other than asked.

The controller also needs the choria-mcorpc-support gem released after
2.27.0, which requires Ruby 3.4 or later. The library reads the loaded
gem's version when a `Client` is built and refuses 2.27.0 or older before
any node is contacted. The fixes that release contains are described in
[docs/library.md](docs/library.md).

## Authorization

The Choria server denies every request to an agent without a policy file.
The module writes `policies/file_transfer.policy` from
`mcollective::policy_default`, `mcollective::site_policies`, and this
module's own policies:

```yaml
mcollective_agent_file_transfer::policies:
  - action: allow
    callers: choria=openbolt.example.net
    actions: "*"
    facts: "*"
    classes: "*"
```

Read-only access grants `stat list get`. Per-path restrictions need Choria's
rego authorization provider, which sees the action arguments as
`input.data.destination` and `input.data.path`. Every chunk of a `put`
includes `destination`, so such a policy applies to every chunk. Pass a
policy file through `mcollective_agent_file_transfer::rego_policy_source`.

The agent runs with the Choria server's privileges and has no allowlist of
its own.

## The client library

The module also ships the client side of the protocol, the MCollective util
plugin `MCollective::Util::FileTransfer`, which the client files install.
It sends files in chunks sized to the broker's message limit, verifies
every file with SHA-256, assembles each file under a temporary name beside
its destination, and returns an outcome per node rather than raising for
one node's failure. OpenBolt's Choria transport is an adapter over it.

A caller sees 2 classes. `Client` takes the gem's client options and the
arguments below, and returns an `Outcome` per node from `upload` and
`download`:

```ruby
require 'mcollective'
require 'mcollective/util/file_transfer'

client = MCollective::Util::FileTransfer::Client.new(options, mutex: @rpc_mutex)

client.upload('/srv/app.tar', '/opt/app/app.tar', ['web1.example.net', 'web2.example.net'])
client.download('/var/log/app.log', { 'web1.example.net' => '/tmp/logs/web1' })
```

`upload` sends a file, or a directory tree, to the same destination on every
node and returns a hash from identity to `Outcome`. A success contains the
path the file was written to, a failure an `error_kind` and an
`error_message`. The kinds are `no_response`, `rpc_error`, `rpc_failed`,
`transfer_failed`, `payload_too_large`, and `checksum_mismatch`. `download`
takes the local directory that receives each node's copy and returns the
same.

The arguments of `Client.new`:

- `options`: the gem's client options hash, the parsed mco options in an
  mco application, the transport's client options in OpenBolt.
- `mutex`: the lock every call runs under, a caller's own when its process
  has other RPC calls to serialize with, like OpenBolt uses. Default is a
  lock of the client's own.
- `logger`: any object with `debug`, `info`, `warn` and `error` methods that
  take a message. Default is `MCollective::Log`.
- `rpc_timeout`: seconds to wait for every node's reply to one call, and to
  publish one call to every node. Default is 300. The wait is never shorter
  than the agent's DDL timeout of 120 seconds, and one window covers a
  whole batch of chunk requests, so a slow link needs a longer wait or a
  smaller `upload_batch_size`.
- `message_data_size`: the data one message contains, in kibibytes, which
  is the file content of a chunk and the biggest a directory listing may
  be. Default is 512, half the Choria broker's message size limit of 1 MiB.
- `upload_batch_size`: how many nodes one chunk request is published to at
  once. Default is 256, which keeps one batch under 256 MiB in memory on
  the controller.

A node that does not answer a chunk is reported as `no_response`, and a
request over the broker's limit fails its nodes with `payload_too_large`
before it is sent, naming a lower message data size as the remedy. Nothing
is retried. How the sizes and the waits were chosen is in
[docs/library.md](docs/library.md).

## Where files are written

Where files are written generally follows the POSIX tool that does the same
job. An upload of a file into a destination that is a directory on a node
is written inside it under the source's name, like `mv` does, and into a
destination whose directory doesn't exist fails that node and creates
nothing, like `scp` does. An upload of a directory tree creates the
destination and its missing parents, like `mkdir -p` then `cp -R` would,
with the parents made under the umask and each directory given the
source's mode. Reading follows a symbolic link to a file and sends what it
points at, like `cp` of a single file does. A walk never goes through a
link to a directory, so it can't loop, and skips it with a warning, since
neither side creates links. A named pipe, a device or a dangling link in a
tree is skipped with a warning on both sides. A download creates the local
directory and one directory per node under it, like OpenBolt does for other
transports, and gives each copy the mode the node reported, under the
umask, with the owner always able to read and write it.

Every file is assembled under the name `.file_transfer-<token>` beside its
destination and renamed into place once verified. The one thing a transfer
can leave behind is such a file, when the caller exited in the middle of it
or the node could not be reached to remove it, and it is safe to remove by
hand.

## Further reading

- [docs/agent.md](docs/agent.md): why the agent is an external agent, its
  6 actions with their inputs and outputs, the temporary file, and the DDL
  files.
- [docs/library.md](docs/library.md): how the client library is layered,
  the message, batch and round sizes and the limits behind them, the
  timeouts, unthreaded publishing, and the gem fixes it depends on.
