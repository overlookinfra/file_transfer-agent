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
| `put` | Write one chunk of a file under a temporary name beside its destination, verify and rename on the last | `destination`, `token`, `offset`, `data`, `final`, `sha256`, `mode` | `bytes`, `size`, `sha256` |
| `abort` | Remove the temporary file of an upload that will not finish | `destination`, `token` | `removed` |
| `get` | Read one chunk of a file | `path`, `offset`, `max_bytes` | `data`, `bytes`, `size` |
| `stat` | Describe a path | `path`, `checksum` | `exists`, `type`, `symlink`, `size`, `mode`, `mtime`, `sha256` |
| `list` | List every entry under a directory | `path`, `max_bytes` | `entries` |
| `mkdir` | Create a directory and missing parents | `path`, `mode` | none |

Chunk `data` is base64 encoded in both directions and never compressed.
Compress a file before sending it when its size matters.

A file arrives chunk by chunk under `.file_transfer-<token>` beside its
destination, `token` being 16 lowercase hex characters the caller chooses
for that one file, until its final chunk, which must carry `sha256`,
verifies it and renames it into place. A `put` that fails removes the
file, and `abort` removes it when the caller gives up on the node. What a
transfer can leave behind is one such file beside a destination, when the
caller died in the middle of it or the node could not be reached for the
abort, and it is safe to remove by hand. Nothing else is ever created or
removed, and the agent reads no settings.

`files/mcollective/agent/file_transfer.json` is the DDL the Choria server
reads. The Ruby DDL next to it is generated from the JSON with

```
choria plugin generate ddl file_transfer.json file_transfer.ddl --convert
```

## Client library

The module also ships the client side of the protocol, the MCollective util
plugin `MCollective::Util::FileTransfer`, which `mcollective_agent_file_transfer`
installs on a client host with `client => true`. It sends files in chunks
sized to the broker's message limit, verifies every file with SHA-256,
assembles each file under a temporary name beside its destination, and
returns an outcome per node rather than raising for one node's failure.
OpenBolt's Choria transport is an adapter over it.

A caller sees two classes. `Client` takes the gem's client options and the
configuration below, and answers `upload` and `download` with an `Outcome`
per node:

```ruby
require 'mcollective'
require 'mcollective/util/file_transfer'

client = MCollective::Util::FileTransfer::Client.new(options, mutex: @rpc_mutex)

client.upload('/srv/app.tar', '/opt/app/app.tar', ['web1.example.net', 'web2.example.net'])
client.download('/var/log/app.log', { 'web1.example.net' => '/tmp/logs/web1' })
```

`upload` sends a file, or a directory tree, to the same destination on every
node and returns a hash from identity to `Outcome`. A success carries the
path the file landed at, a failure a `kind` and a message. The kinds are
`no_response`, `rpc_error`, `rpc_failed`, `transfer_failed`,
`payload_too_large`, and `checksum_mismatch`. `download` takes the local
directory that receives each node's copy and returns the same.

Inside, the Client is the front desk. It checks the request's paths and
starts an `Upload` or a `Download` for it. That object owns the whole
action: it knows its nodes and what happened to each, and its `run` method
is the lifecycle, step by step. Every
step gets the nodes still in play and answers with the failures among them,
plus whatever it produced, such as where each node's file lands. `run`
keeps the failures, drops those nodes from the next step, and at the end
turns the nodes that survived every step into successes, in one place. The
files move through a `Sender` or a `Receiver`, chunk by chunk, and every
chunk, like every other step, is one `Rpc` call: one request to a set of
nodes with their replies. Nothing is shared between layers and nothing
reaches up.

```
callers          mco file_transfer, OpenBolt's Choria transport, any Ruby caller
   |             Client.new(options, mutex: ...), upload, download, an Outcome per node back
   |
Client           the entry: upload, download. Reads the caller's paths as UTF-8 and
   |             refuses invalid ones, builds the Connection and one Rpc from the
   |             options and the sizes, starts a new Upload or Download per call.
   +-------------------+
   |                   |                     every class on the left makes its calls
Upload              Download                 through Rpc, on the right:
one upload, run:    one download: stat         Upload    stat, mkdir
where the source    with a digest, the         Download  stat, list
lands on each       local directories,         Sender    put, abort
node, each file     each file through          Receiver  get
through the Sender  the Receiver, run
   |                   |
Sender              Receiver                 Rpc           one request to a set of nodes, the
one file to the     one file from the           |          replies by identity; the only reader
nodes, chunk by     nodes, chunk by             |          of the gem's replies; the broker's
chunk through       chunk through get,          |          limit, the message data size, the
put, digest at      verified and renamed        |          batch sizes
the end             into place                  |
                                            Connection    the gem's RPC client per call, under
                                                |          the caller's mutex, behind the guard
                                                |
                                            the agent      put, abort, get, stat, list, mkdir
                                            on each node
```

Three rules decide every contract in the library: information goes down as
arguments, results come back up as return values, and an object mutates
only its own state. Each step takes the nodes still pending and returns the
failures among them, `run` carries one pending list that shrinks after
every step, and `Outcome.per_identity` builds the successes once at the
end. `Rpc` is the only code that reads the gem's replies, sorted by
identity at the end of every call.

Reading the library, every file under `files/mcollective/util/file_transfer/`
opens with the sentence that says what it does and does not do. An upload
reads top down as `Client#upload`, `Upload#run` with its steps,
`Sender#send_file` per file, `Rpc#call` per chunk, the agent's `put`. A
download reads as `Client#download`, `Download#run` and `fetch`,
`Receiver#receive_file` per file, `Rpc#call` per round, the agent's
`get`, with the `Receiver` assembling each copy under a temporary name
beside its destination and renaming it into place once it is verified.

The arguments of `Client.new`:

- `options`: the gem's client options hash, the parsed mco options in an
  mco application, the transport's client options in OpenBolt.
- `mutex`: the lock every call runs under, a caller's own when its process
  has other RPC calls to serialize with, as OpenBolt passes its
  transport's. Without it, a lock of the client's own.
- `logger`: any object with `debug(message)`, `warn(message)`, and
  `warn_once(id, message)`. The default writes to `MCollective::Log`.
- `rpc_timeout`: seconds to wait for every node's reply to one call, and to
  publish one call to every node. Default 300. The wait ends a call on a
  node that will never answer rather than bounding a healthy transfer,
  and one window covers a whole batch of chunk requests, so a slow link
  needs a longer wait or a smaller `upload_batch_size`. The wait is never
  shorter than the agent's DDL timeout, 120 seconds, within which a node's
  server stops any request.
- `message_data_size`: the data one message carries, in kibibytes, which
  is the file content of a chunk and the most a directory listing may
  weigh. Without it, half the broker's message size limit, 512 at the
  NATS default of 1 MiB.
- `upload_batch_size`: how many nodes one chunk request is published to at
  once. Without it, the largest number that keeps one batch under 256 MiB
  in memory on the client at the broker's limit.

Each message carries half the limit the broker advertises by default,
512 KiB of file content at the default 1 MiB, which leaves the other
half for the signed envelope, the two base64 passes, and the transport
headers around it, as the design document accounts for. A download round
asks for the same, since a reply carrying it weighs less than a request:
the node signs nothing and sends no certificate. A directory listing is
asked for under the same size, and a node whose tree lists larger refuses
it. A publish guard refuses a request over the limit before it leaves the
client and fails those nodes with `payload_too_large`, naming a lower
message data size as the remedy. A node that does not answer a chunk is
reported as `no_response`. Nothing is retried.

The library publishes unthreaded and forces that on every client it
builds, whatever `threaded` says in the client configuration or in the
options. MCollective's threaded publisher runs in a thread nothing waits
for, so the guard's refusal would be lost there and the nodes would read
as `no_response`. Threaded publishing may be revisited in a later
version.

A chunk request is published once per node, and the client holds every
copy in memory until it is written, so a chunk goes to `upload_batch_size`
nodes at a time through MCollective's batched requests, each batch with
its own publish and reply windows. One `rpc_timeout` window covers one
batch's requests on the wire, 256 MiB at the default batch size.

Every reply of a download round lands on the client's one broker
connection, and the broker closes a connection whose unread backlog passes
64 MiB, stalling the senders above three quarters of that. A download
round therefore asks the largest number of nodes at a time that keeps one
round of replies at their wire size under that threshold, 48 at the NATS
default of 1 MiB.

### Command line

The client files also install `mco file_transfer`:

```
mco file_transfer upload /srv/app.tar /opt/app/app.tar -I web1.example.net -I web2.example.net
mco file_transfer download /var/log/app.log /tmp/logs -F role=web
```

`upload` sends a file or directory tree to the destination on every matched
node. `download` fetches the source from every matched node into a directory
under `DIRECTORY` named after the node, such as
`DIRECTORY/web1.example.net/app.log`. The usual filters select the nodes,
and `--rpc-timeout`, `--message-data-size` and `--upload-batch-size` map
onto the client arguments above. mco's own
`--timeout` has no effect on this command, which is why it has a flag of
its own, and `--discovery-timeout` bounds the discovery of the nodes.
`--one`, `--limit-nodes` and `--batch` are
refused, since the library addresses every node it is given and batches
on its own. The exit code follows mco commands: 0 when every node
succeeded, 2 when any failed, 3 when no node responded, and 1 when no
node matched.

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
is true, and the client library and `mco file_transfer` where
`mcollective::client` is true, through `mcollective::module_plugin`. The
Choria module sets `mcollective::client` to false by default, so the host
that runs `mco file_transfer` or OpenBolt needs it set to true, or
`mcollective_agent_file_transfer::client: true` for this module alone. The
files land under `mcollective/` in the Choria libdir,
`/opt/puppetlabs/mcollective/plugins` by default. The Choria server picks
up the agent without a restart. Without Puppet, the
files listed in `data/plugin.yaml` go under `mcollective/` in the Choria
libdir of a server or a client. The agent reads no settings, so
`mcollective_agent_file_transfer::server_config` needs no keys.

The agent runs on Linux, macOS, and Windows nodes under the Puppet agent's
Ruby. The agent, the client library, and the command need Ruby 3.2 or
later, and use nothing that Ruby 4.0 removed or moved out of its default
gems. On POSIX nodes the server runs the script through its shebang,
`/opt/puppetlabs/puppet/bin/ruby`. On Windows the server resolves the
agent's name through `PATHEXT`, so the module installs `file_transfer.bat`
beside the script, which runs it with the Puppet agent's `ruby.exe` at its
default path. There the last component of a destination may not carry a
colon, a reserved device name such as `CON` or `COM1`, or a trailing dot
or space, since Windows would put the file somewhere other than asked.

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
carries `destination`, so such a policy applies to every chunk. Pass a
policy file through `mcollective_agent_file_transfer::rego_policy_source`.

The agent runs with the Choria server's privileges and has no allowlist of
its own.
