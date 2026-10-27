# The agent

## Actions

| Action | Purpose | Inputs | Outputs |
|--------|---------|--------|---------|
| `put` | Write one chunk of a file under a temporary name beside its destination, verify and rename on the last | `destination`, `token`, `offset`, `data`, `final`, `sha256`, `mode` | `bytes`, `size`, `sha256` |
| `abort` | Remove the temporary file of an upload that will not finish | `destination`, `token` | `removed` |
| `get` | Read one chunk of a file | `path`, `offset`, `max_bytes` | `data`, `bytes`, `size` |
| `stat` | Describe a path | `path`, `checksum` | `exists`, `type`, `symlink`, `size`, `mode`, `mtime`, `sha256` |
| `list` | List every entry under a directory, each regular file with its digest when asked | `path`, `max_bytes`, `checksum` | `entries` |
| `mkdir` | Create a directory and missing parents | `path`, `mode` | none |

Chunk `data` is base64 encoded in both directions and uncompressed for
simplicity. Compress a file before sending it when its size matters.

## The temporary file

A file arrives chunk by chunk under `.file_transfer-<token>` beside its
destination, `token` being 16 lowercase hex characters the caller chooses
for that one file, until its final chunk, which must include `sha256`,
verifies it and renames it into place. A `put` that fails removes the
file, and `abort` removes it when the caller gives up on the node.

## The DDL files

`files/mcollective/agent/file_transfer.json` is the DDL the Choria server
reads. The Ruby DDL next to it is generated from the JSON with

```
choria plugin generate ddl file_transfer.json file_transfer.ddl --convert
```
