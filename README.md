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
