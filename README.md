# file_transfer agent

A Choria external agent that moves files to and from nodes in chunks over
standard Choria RPC, with whole-file SHA-256 verification. OpenBolt's Choria
transport uses it for `upload` and `download` and for delivering task files
that do not fit inline.

Every chunk is a signed, base64-encoded RPC round trip, so transfers through
Choria are far less efficient than a download from a file server. The agent
is meant for smaller files. Gigabytes belong on a file server.

## Actions

| Action | Purpose | Inputs | Outputs |
|--------|---------|--------|---------|
| `mktemp` | Create a session directory, sweep stale sessions | `session` | `path`, `swept` |
| `put` | Write one chunk into a session, verify and move on the last | `session`, `name`, `offset`, `data`, `compressed`, `final`, `sha256`, `destination`, `mode` | `bytes`, `size`, `sha256` |
| `cleanup` | Remove a session directory | `session` | `removed` |
| `get` | Read one chunk of a file | `path`, `offset`, `max_bytes`, `compress` | `data`, `bytes`, `compressed`, `eof`, `size` |
| `stat` | Describe a path | `path`, `checksum` | `exists`, `type`, `symlink`, `size`, `mode`, `mtime`, `sha256` |
| `list` | List one page of a directory | `path`, `offset`, `limit` | `entries`, `total` |
| `mkdir` | Create a directory and missing parents | `path`, `mode` | `created` |

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
