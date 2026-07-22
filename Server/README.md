# Dedicated worker helper

`terminal-relay-session` is the root-owned `/usr/local/bin/terminal-relay-session`
entry point used by Terminal Relay clients. The worker needs Bash, `flock`,
`/usr/bin/python3` with Linux pidfd support, and tmux (Worker 1 currently uses
tmux 3.4), plus Codex and Claude at their standard `/usr/bin` paths. Projects are
immediate directories below `/workspace`.

## Bootstrap a fresh worker

Version 1 supports a fresh Hetzner Ubuntu 24.04 amd64 host with at least 4 GB of
RAM and key-based `root` SSH access. From the repository root on the Mac, use:

```bash
./Scripts/bootstrap-worker.sh [--identity PATH] [--port N] root@host
```

The host may be an IP address, DNS name, or SSH config alias.

The local script verifies `/Applications/Terminal Relay.app` (bundle identifier
`com.mpieras.TerminalRelay`) and the authenticated GitHub CLI, keeps normal
OpenSSH host-key checks, and asks once for confirmation after showing the
resolved destination, host-key fingerprint, existing hostname, OS, and
architecture. It sends this directory's installer and configuration to the host
without provisioning the Hetzner server or changing `sshd`, root SSH access,
firewall policy, or Tailscale.

`install-worker.sh` is root-only and idempotent. Before privileged writes it
requires Ubuntu 24.04, amd64, at least 4 GB of RAM, and no conflicting worker
account, managed path, or non-empty `/workspace`. It then:

- persists a generated UUID in `/etc/terminal-relay/worker-id`, records
  `terminal-relay-worker-v1` in `/etc/terminal-relay/installer-version`, and
  derives the stable `terminal-relay-worker-<first-eight-UUID-hex>` hostname and
  a stable display name in `/etc/terminal-relay/display-name`; a preassigned
  `terminal-relay-worker-<number>` hostname becomes the friendly **Terminal
  Relay Worker <number>** app name, while other hosts use the UUID's short form;
- creates the password-locked `terminal-relay` login account, copies the root
  account's authorized keys with strict permissions, and creates its writable
  `/workspace`;
- installs the explicit OS dependencies, Codex's official standalone release,
  and Claude's signed stable apt package, exposing `/usr/bin/codex` and
  `/usr/bin/claude` without using npm;
- installs this helper as root-owned mode `0755` and installs the worker-wide
  guidance as the unprivileged account.

After remote readiness checks, the local script reconnects as `terminal-relay`.
It runs `codex login --device-auth` and `claude auth login` interactively only
when their status checks show that authentication is missing. Both checks must
pass before the script writes a mode-`0600`, one-time local proof and opens the
generated registration URL in Terminal Relay. The app consumes that proof before
it accepts the externally invokable URL.
Replaying bootstrap reuses the stable UUID and updates one app profile; it does
not duplicate the worker or replace valid credentials.

The managed server surface is `/etc/terminal-relay`, `/home/terminal-relay`,
`/workspace`, the two agent executable paths, this helper, and the guidance
files beneath the worker's home directory. A changed launcher or Claude apt
key/source gets a sibling `.backup.<UTC-timestamp>` copy (with a numeric suffix
when needed), and an install failure restores files changed during that run. The
UUID and installer marker intentionally remain after a partial failure. To
recover from an interruption, rerun the exact bootstrap command so it resumes
the same worker identity. If preflight instead reports an unexpected existing
user, path, or workspace content, inspect and resolve that conflict rather than
deleting it blindly; the installer deliberately leaves the root SSH recovery
route intact.

## Install or update only the helper

From the repository root, install the helper with the application SSH target and
an optional privileged SSH target:

```bash
./Scripts/install-worker-session-helper.sh \
  terminal-relay-worker-1 \
  root@terminal-relay-worker-1
```

Those are also the defaults, so `./Scripts/install-worker-session-helper.sh` is
equivalent. The installer verifies the application account and exact
`/usr/bin/tmux`, `/usr/bin/flock`, and `/usr/bin/python3` pidfd support; verifies
that the admin connection reaches the same hostname and machine ID; and rechecks
both identity values inside the actual install SSH connection before any managed
write. It then uses either the root account or non-interactive `sudo`. The full
inspect, backup, stage, atomic rename, verification, and automatic-restore path
holds the root-owned `/run/lock/terminal-relay-session-helper.lock`. A truly
unchanged `root:root` mode-`0755` helper causes no managed write. Otherwise a
differing helper is retained as a timestamped backup and the new helper is
staged beside the destination and atomically renamed into place. A failed
install or verification restores the retained backup automatically while still
holding the lock. The printed rollback takes that same lock before its guard
checks and holds it through mutation, rechecks worker identity, refuses
symlinks, and requires the installed SHA-256 and inode state to still match this
deployment, so it cannot race or overwrite or delete a later deployment.

Run the isolated local helper coverage before installation:

```bash
./Server/Tests/terminal-relay-session-tests.sh
```

The test owns a unique tmux socket label, temporary workspace, runtime directory,
stub agents, a real `flock(2)` adapter, and an isolated process-identity signal
adapter. It covers concurrent first starts, multi-client reattach, stale instance
rejection, a paused reattach across replacement, configure failure,
stubborn-agent TERM/KILL escalation, and actual agent-lock release. Its cleanup
targets only those private resources.

## Version 1 command contract

Machine-readable discovery responses begin with this marker:

```text
__TERMINAL_RELAY_SESSION_V1__
```

The commands are:

```text
terminal-relay-session list-projects
terminal-relay-session status
terminal-relay-session start <codex|claude> <repository> [agent arguments...]
terminal-relay-session attach <codex|claude> <repository> [agent arguments...]
terminal-relay-session reattach <codex|claude> <repository> <instance-uuid>
terminal-relay-session stop <codex|claude> <repository> <instance-uuid>
```

`list-projects` emits sorted `project|<repository>` records. Names must match
`^[A-Za-z0-9._-]+$`, contain at most 100 characters, and name real immediate
directories (not symlinks) below `/workspace`.

`status` emits one record for each active agent:

```text
session|<codex|claude>|<repository>|<attached-client-count>|<instance-uuid>
```

The instance is a canonical lowercase UUID and changes on every new agent
launch. `start` is the non-PTY, create-or-identify operation used by apps. Under
the per-tool control lock it starts the repository when the slot is empty, or
returns the existing same-repository launch while ignoring new arguments. Its
response is the marker followed by that launch's exact five-field session
record. A different repository receives exit status `75`.

`reattach` never creates. Under the same lock it requires an exact tool,
repository, and instance match, then attaches to the tmux session whose name
contains that immutable UUID. An absent, ended, or replaced launch exits `75`,
including if replacement occurs between lock release and the tmux client exec.
Apps therefore use `start` followed by exact `reattach` rather than a
status-then-create-capable attach sequence.

`attach` remains create-capable for legacy clients: it creates when absent or
attaches the same-repository launch without evicting existing clients. Only the
first launch's arguments are used.

For compatibility, `<codex|claude> [agent arguments...]` infers the immediate
project name from the current directory inside `/workspace/<repository>` and
otherwise behaves like `attach`. `stop` requires the exact repository and
instance UUID. A stale or mismatched request exits `75` without touching the
active launch. A matching stop ends the exact UUID-named tmux session. Before
each required TERM or KILL in production it opens a Linux pidfd, verifies the
recorded `/proc` start identity while that lifetime-bound descriptor is open,
and signals only through the pidfd. Missing pidfd support fails closed. Stop
reports success only after the actual agent lock is released.
There is intentionally no detach RPC: closing SSH, Terminal Relay, or an
individual terminal only disconnects that tmux client.

The dedicated tmux socket label is `terminal-relay`. Sessions are uniquely named
`terminal-relay-<tool>-<instance-uuid>`, preventing a stale attach handoff from
targeting a replacement. Its status bar is disabled.
Pane titles are emitted to attached terminals so Codex title/run-state updates
continue to reach SwiftTerm. tmux does not forward Claude's plain OSC 9;4
progress sequence in this relay path (confirmed with tmux 3.6a even when
passthrough is enabled), so that progress-only signal cannot cross this helper;
the agent session and ordinary terminal output are not affected. Repository
metadata and the control and agent locks live below
`/run/user/<uid>/terminal-relay`. The original nonblocking `flock`
still surrounds the actual Codex or Claude process, preserving the one-Codex and
one-Claude limit even if a tmux session is started unexpectedly. Codex MCP
servers declared in system, user, or project config are disabled at launch;
Claude receives its client-supplied strict MCP arguments unchanged.

For the isolated integration test only, a helper invoked from a path other than
`/usr/local/bin/terminal-relay-session` accepts these settings:

- `TERMINAL_RELAY_TEST_MODE=1` (required)
- `TERMINAL_RELAY_TEST_TMUX_PATH`
- `TERMINAL_RELAY_TEST_TMUX_SOCKET`
- `TERMINAL_RELAY_TEST_WORKSPACE_ROOT`
- `TERMINAL_RELAY_TEST_RUNTIME_ROOT`
- `TERMINAL_RELAY_TEST_CODEX_PATH`
- `TERMINAL_RELAY_TEST_CLAUDE_PATH`
- `TERMINAL_RELAY_TEST_FLOCK_PATH`
- `TERMINAL_RELAY_TEST_SIGNAL_PATH`

The suite also uses narrowly scoped configure-failure and pre-attach pause hooks.
Overrides without explicit test mode are refused. The installed helper refuses
every `TERMINAL_RELAY_TEST_*` variable and always uses the fixed production
paths and socket label.

## Worker guidance

`worker-config/` is the source of truth for worker-wide Codex and Claude
guidance. From the repository root, run
`./Scripts/sync-worker-guidance.sh [ssh-target ...]`; it defaults to
`terminal-relay-worker-1`. The worker installer updates `~/AGENTS.md`,
`~/CLAUDE.md`, `~/.codex/AGENTS.md`, and `~/.claude/CLAUDE.md`, preserving each
differing file as a timestamped adjacent backup.
