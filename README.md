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
is true, through `mcollective::module_plugin`. The files land under
`mcollective/` in the Choria libdir, `/opt/puppetlabs/mcollective/plugins`
by default. The Choria server picks up the agent without a restart. Without
Puppet, the files listed in `data/plugin.yaml` go under `mcollective/` in
the Choria libdir of a server. The agent reads no settings, so
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
