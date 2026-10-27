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
is true, through `mcollective::module_plugin`. The files are installed
under `mcollective/` in the Choria libdir,
`/opt/puppetlabs/mcollective/plugins` by default. The Choria server picks
up the agent without a restart. Without Puppet, the files listed in
`data/plugin.yaml` go under `mcollective/` in the Choria libdir of a
server. The agent reads no settings, so
`mcollective_agent_file_transfer::server_config` needs no keys.

### Requirements

The agent needs Ruby 3.2 or later, and uses nothing that Ruby 4.0 removed
or moved out of its default gems. It runs on Linux, macOS, and Windows
nodes under the Puppet agent's Ruby and loads only the standard library.
On POSIX nodes the server runs the script through its shebang,
`/opt/puppetlabs/puppet/bin/ruby --disable-gems`, which skips rubygems,
most of a Ruby start. On Windows the server resolves the agent's name
through `PATHEXT`, so the module installs `file_transfer.bat` beside the
script, which runs it with the Puppet agent's `ruby.exe` at its default
path and the same flag. There the last component of a destination may not
contain a colon, a reserved device name such as `CON` or `COM1`, or a
trailing dot or space, since Windows would put the file somewhere other
than asked.

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

## Further reading

- [docs/agent.md](docs/agent.md): why the agent is an external agent, its
  6 actions with their inputs and outputs, the temporary file, and the DDL
  files.
