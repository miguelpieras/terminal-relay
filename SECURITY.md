# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
**Report a vulnerability** action in the repository Security tab so the report,
discussion, and any proof of concept remain private.

Include the affected version, impact, reproduction steps, and the smallest safe
proof of concept. Remove credentials, private addresses, account details,
terminal contents, and worker data before attaching logs.

The maintainer will acknowledge a complete report as soon as practical,
coordinate a fix and disclosure privately, and credit reporters who want public
recognition.

## Supported versions

Security fixes are made on `main` and shipped in the newest available release.
Older builds are not supported after an update is published.

## Security model

Terminal Relay is a client for infrastructure controlled by its user:

- SSH private keys remain in the macOS filesystem or iOS Keychain.
- Agent credentials and repositories remain on user-configured workers.
- Multi-account tasks bind to the composite identity of worker, provider,
  account UUID, and provider thread UUID. The worker resolves the UUID to a
  provider-native profile path; clients cannot supply credential paths. Missing
  or mismatched accounts fail before provider traffic and never fall back.
- Codex profiles use separate `CODEX_HOME` roots and app-server sockets. Claude
  profiles use separate `CLAUDE_CONFIG_DIR` roots. This guarantees deterministic
  routing for one trusted owner; directories owned by the same Unix user are not
  a hostile-tenant boundary against a deliberately malicious full-access task.
- Worker host keys are verified or explicitly pinned.
- The project does not operate a shared Terminal Relay backend.
- Provider thread IDs and relay instance UUIDs are separate identities. Resume
  uses the provider thread ID; attach and stop remain bound to the immutable
  relay UUID so stale clients cannot target a replacement agent.
- Native chat uses versioned, size- and depth-bounded NDJSON over authenticated
  SSH without a PTY. Each live broker has an owner-only Unix socket, no TCP
  listener, a bounded per-client queue and replay ring, canonical repository
  validation, provider-thread locking, command idempotency, and exact-instance
  stop protection.
- Chat attachments use one typed SSH upload operation with bytes on standard
  input. The worker binds every file to the exact relay, turn request, and
  attachment UUID; writes it atomically with owner-only permissions; enforces
  per-file and per-turn bounds; and rejects links, special files, unsafe paths,
  ownership or mode changes, and byte-count mismatches.
- Temporary attachment requests are removed after completed, failed, or
  interrupted turns, rejected provider submissions, explicit cancellation,
  and broker startup or shutdown. A bounded orphan sweep removes abandoned
  requests without touching active turns or repository files.
- Provider history remains authoritative. The broker and clients keep bounded
  conversation state in memory and never add a Terminal Relay transcript
  database. Broker recovery metadata contains identifiers and state, not
  prompts, responses, tool payloads, diffs, approvals, or file previews.
- Markdown raw HTML and automatic remote images are disabled. External links
  accept only validated credential-free `http` and `https` URLs; repository
  previews reject directories, binaries, symlink escapes, and paths outside
  the selected repository.
- Before multi-account activation, the built-in MCP is a root-owned,
  worker-local stdio process. It delegates
  seven typed project/thread operations to the fixed helper path, validates
  project and UUID inputs, bounds runtime and output, and exposes no shell,
  terminal input, transcript access, deletion, listener, or cross-worker route.
- Multi-account activation disables ambient MCP and rejects accountless legacy
  clients before provider launch. Task-scoped MCP and account-aware iPhone/iPad
  support must use the same immutable route before they can be enabled.
- Worker runtime releases are described by an Ed25519-signed manifest with an
  exact file allowlist, destinations, modes, and SHA-256 digests. The root
  updater has one compiled-in HTTPS feed, accepts no arguments, rejects
  rollback versions, stages and verifies before taking deployment locks, and
  restores the previous runtime on installation failure.
- macOS and paired-mobile SSH gateways may invoke only typed helper operations.
  Their runtime-update operation can create one fixed trigger for the
  root-owned service; it cannot supply a URL, path, version, shell command,
  systemd unit, or arbitrary network request. Existing paired-mobile keys are
  migrated to this forced-command gateway during the one-time reconciliation.
- Runtime installation never migrates or deletes `/workspace`, provider
  credentials or history, relay metadata, restart intent, or tmux processes.
  Runtime status is intentionally limited to versions, timestamp, result, and
  a safe failure code.
- App and worker diagnostics contain identifiers, state transitions, counts,
  sizes, and sanitized error categories only. They must never include raw
  structured records, terminal contents, provider objects, secret answers, or
  fetched file content, attachment names, attachment paths, or attachment
  bytes.

Users are responsible for their worker operating systems, Tailscale policy,
SSH authorization, agent accounts, repository permissions, backups, and
credential rotation.
