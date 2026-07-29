# Terminal Relay chat protocol v1

Terminal Relay chat is a bidirectional NDJSON stream carried inside the same
authenticated SSH connection as the existing worker commands. It has no TCP
listener, central service, or transcript database. One worker-local broker owns
each provider conversation; macOS, iPhone, and iPad attach to that broker.

The provider's local history remains authoritative. The broker holds a bounded
materialized snapshot and replay window in memory only. Clients hold the
currently rendered conversation in memory only and request a fresh provider
snapshot after a replay gap or broker restart.

## Transport

`terminal-relay-session chat-attach-v1` opens an SSH exec channel without a
PTY. Standard input and standard output carry UTF-8 NDJSON. Standard error is
reserved for sanitized transport diagnostics and never contains protocol
payloads or provider content.

Each record is one JSON object followed by `LF`; readers also accept `CRLF`.
Strings contain escaped newlines. A reader must retain partial UTF-8 scalars
and partial records across arbitrary SSH chunks.

The first client record is `session.attach`. The first server record is either
`session.hello` or `error`. After the hello, the server sends a replay or a
complete `conversation.snapshot` before forwarding newer live events.

## Limits

The worker and clients enforce the same limits before allocating or decoding:

| Value | Limit |
| --- | ---: |
| Encoded NDJSON record | 1 MiB |
| JSON nesting depth | 32 |
| Prompt text | 256 KiB UTF-8 |
| Attachment references per turn | 32 |
| One attachment path | 4 KiB UTF-8 |
| One content/tool item | 1 MiB UTF-8 |
| File preview | 256 KiB |
| History page | 100 messages and 4 MiB encoded |
| Per-client queued output | 512 records or 4 MiB |
| Broker replay window | 2,048 records or 8 MiB |
| Remembered command results | 1,024 IDs |

A client may request 1–100 older messages; the default is 50. Oversized
provider content is represented by a visible truncated item with its original
byte count. It is never silently omitted.

The broker emits a heartbeat after 20 seconds without another outbound event.
A client treats 65 seconds without data as a lost attachment and reconnects
with its last applied sequence.

## Identity

Identifiers are never interchangeable:

- `relayId` is the lowercase UUID of one Terminal Relay broker instance. It is
  the only identifier accepted by exact attach and stop operations.
- `providerThreadId` is the provider's canonical Codex thread or Claude
  session UUID. History and resume use this value.
- `turnId` identifies one user turn. Codex supplies it. Claude turns reconcile
  to the replayed top-level human message UUID.
- `itemId` identifies one provider item. Items are keyed by provider thread
  plus item ID; Claude content blocks also include their block index.
- `requestId` is the lowercase client-generated UUID for one command.
- `eventId` is a lowercase broker-generated UUID for one server record.
- `seq` is a positive, monotonically increasing integer assigned once by the
  broker before an event is broadcast.
- `snapshotGeneration` is a lowercase UUID that changes whenever the broker
  replaces materialized state from provider history.

Stopping by provider thread ID, repository name, provider kind, timestamp, or
UI selection is forbidden. A chat-to-terminal transition finishes or
interrupts the current turn, stops the exact chat relay, verifies that the
provider thread lock was released, and starts a new terminal relay bound to
the same provider thread.

## Envelopes

Every client command contains:

```json
{
  "v": 1,
  "type": "turn.start",
  "requestId": "00000000-0000-4000-8000-000000000000",
  "relayId": "00000000-0000-4000-8000-000000000000",
  "provider": "codex",
  "providerThreadId": "00000000-0000-4000-8000-000000000000",
  "sentAt": 0,
  "payload": {}
}
```

Every sequenced server event contains:

```json
{
  "v": 1,
  "type": "message.delta",
  "eventId": "00000000-0000-4000-8000-000000000000",
  "relayId": "00000000-0000-4000-8000-000000000000",
  "provider": "codex",
  "providerThreadId": "00000000-0000-4000-8000-000000000000",
  "snapshotGeneration": "00000000-0000-4000-8000-000000000000",
  "seq": 1,
  "occurredAt": 0,
  "turnId": null,
  "itemId": null,
  "payload": {}
}
```

Timestamps are Unix milliseconds and are presentation metadata, never
identities. Optional identity fields are omitted or `null` until the provider
supplies them. Unknown top-level fields are ignored. An unknown non-interactive
event becomes a generic expandable item. An unknown interaction that could
block a provider turn emits `session.terminalFallbackRequired`.

## Client commands

| Type | Required payload and behavior |
| --- | --- |
| `session.attach` | `afterSeq`, optional `snapshotGeneration`; read-only and always first |
| `history.load` | `beforeItemId`, `limit`; returns one bounded older page |
| `turn.start` | `text`, `attachments`, launch options; idempotent by `requestId` |
| `turn.interrupt` | exact `turnId`; stale turns are rejected |
| `approval.respond` | provider connection generation, provider request ID, decision, optional permission changes |
| `question.respond` | provider connection generation, provider request ID, structured answers |
| `file.preview` | canonical or repository-relative path plus optional line/column |
| `session.stop` | exact `relayId`; ends the provider connection for every client |
| `session.detach` | closes only this attachment and leaves the broker running |
| `ping` | liveness request with no state mutation |

Every command receives exactly one `ack` or `error` containing its `requestId`.
The broker remembers the bounded set of prior mutation results. Repeating an ID
returns the prior result and never starts another turn, answers twice, or stops
a replacement session. Reusing an ID with a different command or payload is a
protocol error.

## Server events

The v1 event set is:

- `session.hello`, `session.state`, `session.heartbeat`,
  `session.terminalFallbackRequired`, `session.ended`
- `ack`, `error`
- `conversation.snapshot`, `history.page`
- `message.started`, `message.delta`, `message.completed`
- `reasoning.started`, `reasoning.delta`, `reasoning.completed`
- `tool.started`, `tool.updated`, `tool.completed`
- `fileChange.updated`, `diff.updated`, `file.preview`
- `approval.requested`, `approval.resolved`, `approval.expired`
- `question.requested`, `question.resolved`, `question.expired`
- `plan.updated`, `usage.updated`
- `turn.started`, `turn.completed`, `turn.failed`, `turn.interrupted`

Message and reasoning deltas append only to the identified incomplete item.
`*.completed` replaces that item with the provider's authoritative final
content. Tool completion includes bounded final output, status, duration,
exit code or provider error, and file/MCP/dynamic-tool results as applicable.
Approval and question events carry a stable display ID separately from the
provider connection generation and provider request ID.

Connection states are `connecting`, `streaming`, `awaitingApproval`,
`offlineAgentRunning`, `interrupted`, `stopped`, `unsupportedWorker`, and
`failed`. Disconnecting a client does not emit `session.ended`.

## Snapshot and reconnect

`conversation.snapshot` contains the complete currently retained conversation,
turn/tool/request states, connection state, capability set,
`snapshotGeneration`, and `baseSeq`. Applying it replaces local materialized
state. Later events with `seq <= baseSeq` are ignored.

For a matching generation and a cursor inside the replay window, the broker
replays records after `afterSeq`. Otherwise it rebuilds from provider history.
Providers do not expose a sequence watermark, so the broker buffers live
notifications during the rebuild, publishes the new generation atomically,
then reconciles buffered provider items by stable identity. Delta text is
never deduplicated by substring comparison.

A pending provider JSON-RPC/callback request belongs to one provider
connection generation. If that connection dies, the request becomes expired;
a response from a new connection is forbidden. The broker interrupts or
reconciles the turn and emits a fresh snapshot.

## Provider mapping

### Codex

The broker performs `initialize`, waits for the result, then sends
`initialized`. Initialization enables the experimental API and disables
attestation requests. Bindings and fixtures are checked against the managed
worker's Codex v2 schema rather than copied from Happy.

`thread/read(includeTurns: true)` supplies bounded history.
`thread/resume` supplies the subscription snapshot; notifications arriving
around its response are buffered. `item/*` lifecycle records are authoritative
for transcript items. `item/completed` replaces accumulated deltas.
`turn/completed` is the turn boundary. Orderly shutdown calls
`thread/unsubscribe`.

`turn.start` includes a durable `clientUserMessageId` derived from the Terminal
Relay command ID. Interrupt specifies the exact thread and turn and must reach
an authoritative interrupted completion before another turn starts.

Command/file/permission approvals, user-input requests, and MCP elicitations
preserve the provider JSON-RPC ID type and connection generation. Secret
answers exist only long enough to answer the current request and are never
logged or retained.

### Claude

The broker validates the session with `get_session_info` and pages official
`get_session_messages` history. Provider compaction is rendered as the
available current-context boundary; Terminal Relay does not parse Claude JSONL
to recreate removed history.

One persistent `ClaudeSDKClient` runs with partial messages and replayed user
messages enabled. One receive loop remains alive across turns. Partial content
is accumulated by message UUID and block index and replaced by the final
message. Tool results join their `tool_use_id`. `ResultMessage` is the turn
boundary, not the end of the receive loop.

Permission callbacks are keyed by agent ID plus `tool_use_id`.
`AskUserQuestion` is answered as an allowed tool call with structured updated
input, not as a follow-up chat message. Pending callbacks are cleaned on deny,
interrupt, cancellation, timeout, or stop.

## Repository links

`file.preview` accepts only a canonical path below the selected repository or a
validated relative path. The worker resolves the real path, rejects
directories, non-regular files, binaries, symlink escapes, and other
repositories, then returns at most 256 KiB with truncation metadata. Line and
column are bounded positive integers.

Clients open validated `http` and `https` links in the system browser. They
reject embedded credentials, `javascript`, `data`, arbitrary `file`, and
unknown custom schemes. Markdown images never fetch remote resources
automatically; the UI preserves alt text and offers an explicit external-link
action.

## Security and diagnostics

All operations reuse forced-command SSH authorization, pinned host identity,
canonical repository validation, worker-user execution, a safe `PATH`,
provider/thread locks, bounded timeouts, and exact-instance checks. Unix
sockets and state directories are owner-only. Slow readers are detached with
a resumable cursor.

Logs contain identifiers, counts, sizes, timing, state transitions, and
sanitized error categories only. They never contain prompts, responses,
reasoning, tool input/output, diffs, file previews, approval details, secret
answers, account data, provider objects, or raw protocol records.

Workers advertise chat per provider only after the v1 command, broker, and
adapter readiness checks pass. Old clients and old workers retain the existing
terminal protocol. Active TUI sessions are never converted by parsing ANSI
screen output.
