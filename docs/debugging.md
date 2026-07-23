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
- `worker-session`: session refresh, start, and stop results.
- `terminal-session`: terminal attachment start and exit.

The app deliberately does not log authorization URL or code contents,
credentials, or terminal contents.

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

Compare the installed helper with the repository source:

```bash
shasum -a 256 Server/terminal-relay-session
ssh terminal-relay-worker-N \
  'sha256sum /usr/local/bin/terminal-relay-session'
```

Install the tested repository helper on an existing worker with:

```bash
./Scripts/install-worker-session-helper.sh \
  terminal-relay-worker-N root@terminal-relay-worker-N
```

The installer verifies that both SSH targets reach the same machine, installs
atomically, preserves the systemd service state, and prints a rollback command.

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

`Server/terminal-relay-session` is the canonical helper. Fresh-worker bootstrap
includes that file in its payload, and `Server/install-worker.sh` installs it at
`/usr/local/bin/terminal-relay-session`. Therefore newly provisioned workers
receive the fix from the checked-out repository version. Existing workers must
be reconciled with `Scripts/install-worker-session-helper.sh` after a helper
change.

For helper changes, run:

```bash
./Server/Tests/terminal-relay-session-tests.sh
./Scripts/build-and-install.sh
```
