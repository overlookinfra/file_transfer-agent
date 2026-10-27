# Inside the client library

## Layers

The Client is the entry point. It checks the request's paths and starts an
`Upload` or a `Download` for it. That object owns the whole action. It
knows its nodes and what happened to each, and its `run` method is the
lifecycle, step by step. Every step gets the nodes still pending and
returns the failures among them, plus whatever it produced, such as where
each node's file is written. `run` keeps the failures, drops those nodes
from the next step, and at the end turns the nodes that passed every step
into successes, in one place. The files move through a `Sender` or a
`Receiver`, chunk by chunk, and every chunk, like every other step, is one
`Rpc` call, which is one request to a set of nodes with their replies.
Nothing is shared between layers and nothing reaches up.

```
callers          mco file_transfer, OpenBolt's Choria transport, any Ruby caller
   |             Client.new(options, mutex: ...), upload, download, an Outcome per node back
   |
Client           The entry: upload, download. Reads the caller's paths as UTF-8 and
   |             refuses invalid ones, builds the Connection and one Rpc from the
   |             options and the sizes, starts a new Upload or Download per call.
   +-------------------+
   |                   |                     Every class on the left makes its calls
Upload              Download                 through Rpc, on the right:
one upload, run:    one download: stat         Upload    stat, mkdir
where the source    with a digest, the         Download  stat, list
is written on each  local directories,         Sender    put, abort
node, each file     each file through          Receiver  get
through the Sender  the Receiver, run
   |                   |
Sender              Receiver                   Rpc         One request to a set of nodes, the
one file to the     one file from the           |          replies by identity. The only reader
nodes, chunk by     nodes, chunk by             |          of the gem's replies. The message
chunk through       chunk through get,          |          data size, the batch sizes
put, digest at      verified and renamed        |
the end             into place                  |
                                            Connection     The gem's RPC client per call, under
                                                |          the caller's mutex, behind the guard
                                                |          that keeps every message under the
                                                |          broker's limit
                                                |
                                            the agent      put, abort, get, stat, list, mkdir
                                            on each node
```

3 rules decide every contract in the library: information goes down as
arguments, results come back up as return values, and an object mutates
only its own state. Each step takes the nodes still pending and returns the
failures among them, `run` keeps one pending list that shrinks after
every step, and `Outcome.per_identity` builds the successes once at the
end. `Rpc` is the only code that reads the gem's replies, sorted by
identity at the end of every call.

Reading the library, every file under `files/mcollective/util/file_transfer/`
opens with the sentence that says what it does and does not do. An upload
reads top down as `Client#upload`, `Upload#run` with its steps,
`Sender#send_file` per file, `Rpc#call` per chunk, the agent's `put`. A
download reads as `Client#download`, `Download#run` with its steps,
`Receiver#receive_file` per file, `Rpc#call` per round, the agent's
`get`, with the `Receiver` assembling each copy under a temporary name
beside its destination and renaming it into place once it is verified.

## Sizes and limits

Each message contains 512 KiB of file content by default, half the
broker's 1 MiB limit, which is nats-server's default and has no way to
change it in go-choria. The other half is left for the signed envelope,
the 2 base64 passes, and the transport headers around it, as the design
document accounts for. The library defines that limit as one constant,
since the Choria broker has no setting for it and a NATS server other than
Choria's is out of scope. A download round asks for the same, since a reply
containing it is smaller than a request: the node signs nothing and sends
no certificate. A directory listing is asked for under the same size,
measured as the reply contains it, where a quote is 4 bytes, and a node
whose tree lists larger refuses it. The listing contains each regular
file's size, digest and mode, so a tree download describes its files in
that one call and fetches them with no stat per file. A publish guard
refuses a request over the limit before it leaves the client and fails
those nodes with `payload_too_large`.

A chunk request is published once per node, and the client keeps every
copy in memory until it is written, so a chunk goes to `upload_batch_size`
nodes at a time through MCollective's batched requests, each batch with
its own publish and reply windows. At the default of 256 nodes, one batch
stays under 256 MiB at the broker's limit, and one `rpc_timeout` window
covers one batch's requests on the wire.

Every reply of a download round arrives on the client's one broker
connection, and the broker closes a connection whose unread backlog passes
64 MiB, stalling the senders above 3/4 of that. A download round therefore
asks the largest number of nodes at a time that keeps one round of replies
at their wire size under that threshold, 48 at the broker's 1 MiB limit.

## Timeouts

`rpc_timeout` ends a call on a node that will never answer rather than
bounding a healthy transfer. The wait is never shorter than the agent's
DDL timeout, 120 seconds, within which a node's server stops any request,
and every request is sent with the wait as its TTL, so a node still accepts
a copy that a slow link delivers late in the window.

## Unthreaded publishing

The library publishes unthreaded and forces that on every client it
builds, whatever `threaded` says in the client configuration or in the
options. MCollective's threaded publisher runs in a thread nothing waits
for, so the guard's refusal would be lost there and the nodes would read
as `no_response`. Threaded publishing may be revisited in a later
version.

## The gem it runs on

The controller's choria-mcorpc-support gem needs the 3 fixes merged
after its 2.27.0 release: the check on every received message before its
base64 is decoded runs through `String#count` instead of a regex over
the whole message, a direct request is serialized once per batch
instead of once per node, and an explicit `threaded: false` in the client
options wins over the client configuration. The library included the
first 2 as overrides until they were merged. With 2.27.0 every transfer
still works, with the gem's regex costing the controller more per reply
than decoding and parsing the reply together, one serialization per node
per chunk, and a client configuration that turns threading on losing the
publish guard's refusal in the publisher thread.
