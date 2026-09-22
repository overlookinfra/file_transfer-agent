# file_transfer agent

A Choria external agent that moves files to and from nodes in chunks over
standard Choria RPC, with whole-file SHA-256 verification. Any Choria client
can use it to put files on nodes or fetch files from them. It was designed
for OpenBolt's Choria transport, which uses it for `upload` and `download`,
but nothing in it is specific to OpenBolt.

Every chunk is a signed, base64-encoded RPC round trip, so transfers through
Choria are far less efficient than a download from a file server. The agent
is meant for smaller files. Gigabytes belong on a file server.

## Why an external agent

Choria runs a Ruby MCollective agent through a shim that loads the whole
MCollective library for every request, which costs most of a second on a
node before the action runs. An external agent is a plain process that reads
the request from a file and writes the reply to another, and this one loads
only the Ruby standard library, so a request costs a few tens of
milliseconds. A transfer is thousands of requests, one per chunk, and that
difference is the difference between minutes and hours. The server also
validates every input against the JSON DDL before the process starts, so the
agent needs no MCollective runtime on the node at all.

## Actions

| Action | Purpose | Inputs | Outputs |
|--------|---------|--------|---------|
| `mktemp` | Create a session directory, sweep stale sessions | `session` | `path`, `swept` |
| `put` | Write one chunk into a session, verify and move on the last | `session`, `name`, `offset`, `data`, `final`, `sha256`, `destination`, `mode` | `bytes`, `size`, `sha256` |
| `cleanup` | Remove a session directory | `session` | `removed` |
| `get` | Read one chunk of a file | `path`, `offset`, `max_bytes` | `data`, `bytes`, `eof`, `size` |
| `stat` | Describe a path | `path`, `checksum` | `exists`, `type`, `symlink`, `size`, `mode`, `mtime`, `sha256` |
| `list` | List one page of a directory | `path`, `offset`, `limit` | `entries`, `total` |
| `mkdir` | Create a directory and missing parents | `path`, `mode` | `created` |

Chunk `data` is always zlib deflated and then base64 encoded, in both
directions, so a chunk of text costs a fraction of its size on the wire and
an incompressible chunk costs a few milliseconds of deflate on the sending
side.

Temporary storage on the node is addressed only by `session`, a lowercase
UUID the caller chooses, and `name`, a path relative to the session
directory. The agent keeps sessions under `<tmpdir>/file_transfer-<uuid>`
and never accepts another temporary location. `cleanup` removes one session,
and `mktemp` sweeps sessions older than `stale_after`. Nothing else is ever
removed.

`files/mcollective/agent/file_transfer.json` is the DDL the Choria server
reads. The Ruby DDL next to it is generated from the JSON with

```
choria plugin generate ddl file_transfer.json file_transfer.ddl --convert
```

## Client library

The module also ships the client side of the protocol, the MCollective util
plugin `MCollective::Util::FileTransfer`, which `mcollective_agent_file_transfer`
installs on a client host with `client => true`. It sizes chunks to the
broker's payload limit at run time, verifies every file with SHA-256, keeps
temporary files in sessions the agent owns, and answers an outcome per node
rather than raising for one node's failure. OpenBolt's Choria transport is
an adapter over it.

```ruby
require 'mcollective'
require 'mcollective/util/file_transfer'

connection = MCollective::Util::FileTransfer::Connection.new(options)
client = MCollective::Util::FileTransfer::Client.new(connection: connection)

client.upload('/srv/app.tar', '/opt/app/app.tar', ['web1.example.net', 'web2.example.net'])
client.download('/var/log/app.log', { 'web1.example.net' => '/tmp/logs/web1' })

session = client.open_session(['web1.example.net'])
session.put('/srv/facts.json', 'input/facts.json', mode: '0600')
session.cleanup
```

`upload` sends a file, or a directory tree, to the same destination on every
node and answers a hash from identity to `Outcome`. A success carries the
path the file landed at, a failure a `kind` and a message. The kinds are
`no_response`, `rpc_error`, `rpc_failed`, `transfer_failed`,
`payload_too_large`, and `checksum_mismatch`. `download` takes the local
directory that receives each node's copy and answers the same. A session
holds files a caller uses on the node and removes afterwards: `put` sends a
file into it without a destination and answers the nodes that received it,
`cleanup` removes the session on every node whose cleanup setting is on.

The arguments of `Client.new`:

- `connection`: any object with `with_client(agent, identities, timeout:,
  publish_timeout:)`, which yields an `MCollective::RPC::Client` addressing
  those identities directly and serializes the calls, and `nats_wrapper`,
  the connector's `MCollective::Util::NatsWrapper` or nil. `Connection`
  builds one from a client options hash.
- `logger`: any object with `debug(message)`, `warn(message)`, and
  `warn_once(id, message)`. The default writes to `MCollective::Log`.
- `rpc_timeout`: seconds to wait for every node's reply to one call, and to
  publish one call to every node. Default 30.
- `chunk_size`: the most file content one request carries, before the
  broker's limit lowers it. Default 524288.
- `download_group_size`: how many nodes one download round asks at once.
  Default 32.
- `cleanup`: whether sessions are removed afterwards, `true`, `false`, or a
  hash from identity to boolean. Default true.

Chunks are sized from the broker's advertised payload limit and two probe
serializations of a `put` captured at the NATS wrapper without sending, and
a publish guard refuses a request over the limit before it leaves the
client. A whole group that stays silent but answers a ping, or a broker
reconnect during a call, shrinks the chunk by a fifth and retries, with a
warning naming the cause and the remedy. Downloads measure the size of their
replies and size the next round from it.

### Command line

The client files also install `mco file_transfer`:

```
mco file_transfer upload /srv/app.tar /opt/app/app.tar -I web1.example.net -I web2.example.net
mco file_transfer download /var/log/app.log /tmp/logs -F role=web
```

`upload` sends a file or directory tree to the destination on every matched
node. `download` fetches the source from every matched node into
`DIRECTORY/<identity>`. The usual filters select the nodes, `--timeout` is
the wait for every node's reply to one chunk (5 seconds by default), and
`--chunk-size`, `--download-group-size`, and `--keep-session` map onto the
client arguments above. The exit code is 0 when every node succeeded, 2 when
any failed, and 1 when no node matched.

## Installation

```yaml
mcollective::plugin_classes:
  - mcollective_agent_file_transfer
```

The module installs the agent, its DDL files, and its policy file through
`mcollective::module_plugin`. The Choria server picks up the agent without a
restart.

## Configuration

Settings are written to `plugin.d/file_transfer.cfg` on servers:

```yaml
mcollective_agent_file_transfer::server_config:
  tmpdir: /var/lib/file_transfer
  stale_after: 172800
```

- `tmpdir`: the root under which the agent creates session directories.
  Default: Ruby's temp dir, `/tmp` on most nodes. Set it on nodes where
  `/tmp` is mounted noexec if a caller runs files from a session. The
  directory must be owned by the user the Choria server runs as or by root,
  and must not be writable by its group or by others unless it has the
  sticky bit, since anyone who can rename entries in it could swap a
  session for a link.
- `stale_after`: seconds after which an abandoned session is removed by the
  next `mktemp`. Default 86400. It must exceed the longest time a caller
  keeps a session in use, because a session that is only read from does not
  change.

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
`input.data.destination` and `input.data.path`. Pass a policy file through
`mcollective_agent_file_transfer::rego_policy_source`.

The agent runs with the Choria server's privileges and has no allowlist of
its own.
