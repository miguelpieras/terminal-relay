# Terminal Relay debugging

Use this runbook first for account authentication, worker-session, and terminal
launch failures. Replace `N` with the worker number.

## macOS app logs

Terminal Relay writes structured events to the macOS unified log under the
`com.mpieras.TerminalRelay` subsystem. Recent events:

```bash
/usr/bin/log show --last 1h --style compact --info \
  --predicate 'subsystem == "com.mpieras.TerminalRelay"'
```

Follow events while reproducing a problem:

```bash
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem == "com.mpieras.TerminalRelay"'
```

The categories are:

- `account-authentication`: sign-in start, authorization handoff, completion,
  cancellation, and failure.
- `worker-session`: session/thread refresh, start, resume, mutation, and stop
  results.
- `terminal-session`: native-chat and terminal attachment start, reconnect,
  sanitized failure, and exit.

The app deliberately does not log authorization URL or code contents,
credentials, native-chat records, file previews, secret answers, or terminal
contents.

## Worker session checks

Confirm the helper is available and inspect the authoritative live sessions:

```bash
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session status'
```

Inspect boot restoration separately:

```bash
ssh root@terminal-relay-worker-N \
  'systemctl status terminal-relay-session-restore@terminal-relay.service'
ssh root@terminal-relay-worker-N \
  'journalctl -b -u terminal-relay-session-restore@terminal-relay.service --no-pager'
```

Inspect the sanitized automatic-agent update status through the same
unprivileged helper:

```bash
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session update-status'
```

The response should contain only its marker and, after the first timer run, one
timestamp/result/version record. Use the root-only systemd status and journal
commands in `Server/README.md` for the underlying failure. Do not copy package
manager output into a public issue until it has been checked for hostnames,
repository details, account data, or credentials.

Compare the installed helper with the repository source:

```bash
shasum -a 256 Server/terminal-relay-session
shasum -a 256 Server/terminal-relay-mcp
shasum -a 256 Server/terminal-relay-claude-sessions
ssh terminal-relay-worker-N \
  'sha256sum /usr/local/bin/terminal-relay-session /usr/local/bin/terminal-relay-mcp /usr/local/bin/terminal-relay-claude-sessions'
```

Install the tested repository helper on an existing worker with:

```bash
./Scripts/install-worker-session-helper.sh \
  terminal-relay-worker-N root@terminal-relay-worker-N
```

The installer verifies that both SSH targets reach the same machine, installs
atomically, and preserves the systemd service state. It leaves no retained host
copies by default. Use `--retain-backups` only when a host-side rollback was
explicitly requested; that mode prints a guarded rollback command.

## Native chat is unavailable or reconnecting

Check capability negotiation without starting a turn or reading provider
history:

```bash
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session chat-capabilities-v1 codex example-repository'
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session chat-capabilities-v1 claude example-repository'
```

A ready adapter returns `__TERMINAL_RELAY_CHAT_V1__` followed by one bounded
capability object. A missing marker means the worker predates structured chat.
An unavailable result means the selected provider adapter failed its readiness
check; existing terminal sessions remain usable.

For a chat that already exists, compare only its provider, repository, exact
relay UUID, and `chat` presentation in the normal `status` response. Do not
print the broker's NDJSON stream, provider app-server traffic, SDK message
objects, or transcript files. A local app disconnect should leave that status
row present with zero attached clients. **Stop Agent** should remove only the
row with the matching relay UUID.

If the app reports a sequence gap, leave the agent running and use
**Reconnect** once. The client reattaches with its last cursor; the broker
replays its bounded window or rebuilds an authoritative snapshot from the
provider. Persistent protocol errors should be reproduced with the app's
sanitized `terminal-session` logs and the focused local suites:

```bash
./Server/Tests/terminal-relay-chat-tests.py
./Server/Tests/terminal-relay-chat-session-tests.py
```

**Open Terminal Fallback** is an explicit same-thread migration. If stopping
the exact chat relay or releasing its provider lock fails, the operation must
fail closed and must not open a PTY. Retry the migration or stop that exact
agent before starting a terminal session; never bypass the lock or run both
modes against the same provider thread.

## Thread catalog or built-in MCP is unavailable

Inspect open and archived metadata for one repository without reading its
transcripts:

```bash
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session threads-v2 codex example-repository open'
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session threads-v2 claude example-repository open'
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session threads-v2 claude example-repository archived'
```

Each successful response contains `__TERMINAL_RELAY_THREADS_V2__` followed by
one bounded JSON catalog. A missing marker usually means the worker has an older
helper; existing live terminals continue to work and the helper-only installer
above upgrades the helper, MCP, Claude adapter, and pinned SDK.

Verify only the installed adapter version:

```bash
ssh terminal-relay-worker-N \
  '/opt/terminal-relay/claude-session-sdk/current/bin/python3 /usr/local/bin/terminal-relay-claude-sessions version'
```

An expected catalog row has an `activityState` of `inactive`,
`relay-active`, `external-active`, or `unknown`. External-active and unknown
rows are intentionally read-only. If every Claude row is unknown, first verify
that `claude agents --json` is supported, but do not paste its raw output into a
public issue: it can contain process and working-directory metadata. If the SDK
or activity query is unavailable, the helper returns a sanitized provider
catalog error and existing relay terminals continue to work.

Do not inspect `~/.claude/projects`, copy Claude JSONL files, or print a session
object to diagnose cataloging. The adapter deliberately emits only UUID, title,
activity time, archive state, and activity state.

Check the MCP handshake and discovered tool names locally on the worker:

```bash
ssh terminal-relay-worker-N \
  "printf '%s\n' \
  '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}' \
  '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}' \
  | /usr/local/bin/terminal-relay-mcp"
```

Expected tools are `list_projects`, `list_threads`, `start_thread`,
`resume_thread`, `rename_thread`, `archive_thread`, and `unarchive_thread`.
The process exits at end-of-input. Do not add an HTTP wrapper or paste
unredacted app-server, agent, or terminal output into an issue.

Codex receives the MCP through the shared app-server configuration. If the
binary changed while Codex terminals were live, reconciliation records a
pending app-server restart and completes it after those terminals drain.
Claude receives the same fixed executable through its strict per-launch MCP
configuration.

## Codex account and terminal disagree

Terminal Relay uses one persistent Codex app-server per worker as the account
authority. Account reads, device login, rate-limit reads, reset redemption, and
every Codex terminal all connect to that same process. A new Codex terminal is
refused when that shared process is signed out.

Check the shared account response without printing or copying it into an issue:

```bash
ssh terminal-relay-worker-N \
  '/usr/local/bin/terminal-relay-session codex-account'
```

The response can include the account email and reset-credit identifiers. It
must never include OAuth tokens or API keys.

Workers with a Codex terminal started by an older helper need a one-time
migration: use **Sign In** in Terminal Relay, then stop and restart the old
terminal. New terminals and all later account reads then use the shared
app-server automatically.

## Claude reports signed in but opens login

Check Claude's own authentication result without printing its credentials:

```bash
ssh terminal-relay-worker-N \
  "/usr/bin/claude auth status --json | /usr/bin/python3 -c \
  'import json,sys; print(json.load(sys.stdin).get(\"loggedIn\"))'"
```

Check only the interactive onboarding marker:

```bash
ssh terminal-relay-worker-N \
  "/usr/bin/python3 -c \
  'import json,pathlib; p=pathlib.Path.home()/\".claude.json\"; \
  d=json.loads(p.read_text()) if p.exists() else {}; \
  print(d.get(\"hasCompletedOnboarding\"))'"
```

Claude Code can leave valid OAuth credentials while omitting
`hasCompletedOnboarding`, which makes its interactive terminal enter the
first-run login flow. Before every Claude start or boot restoration,
`terminal-relay-session` now:

1. Leaves an already-completed configuration unchanged.
2. Verifies `claude auth status --json` reports `loggedIn: true`.
3. Atomically sets only `hasCompletedOnboarding` while preserving the rest of
   `~/.claude.json`.
4. Returns an explicit sign-in error when Claude is not authenticated.

The helper refuses symlinked, non-regular, invalid, or wrong-owner configuration
files instead of overwriting them.

Never print or copy `~/.claude/.credentials.json`, authorization codes, full
authorization URLs, or unredacted terminal captures into logs or issues.

## Current and future workers

`Server/terminal-relay-session`, `Server/terminal-relay-mcp`, and
`Server/terminal-relay-claude-sessions` are the canonical worker control
executables. Fresh-worker bootstrap includes all three plus the pinned SDK
requirements, and `Server/install-worker.sh` installs them at their fixed
paths. Existing workers must be reconciled with
`Scripts/install-worker-session-helper.sh` after any of them or the SDK lock
changes.

For helper changes, run:

```bash
./Server/Tests/terminal-relay-session-tests.sh
./Server/Tests/terminal-relay-mcp-tests.sh
./Server/Tests/terminal-relay-claude-sessions-tests.py
./Scripts/build-and-install.sh
```
