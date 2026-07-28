# Dedicated worker helper

`terminal-relay-session` is the root-owned `/usr/local/bin/terminal-relay-session`
entry point used by Terminal Relay clients. `terminal-relay-mcp` is the
root-owned `/usr/local/bin/terminal-relay-mcp` stdio MCP exposed inside managed
Codex and Claude terminals. The worker needs Bash, `flock`, `/usr/bin/python3`
with Linux pidfd support, and tmux, plus Codex and Claude at their standard
`/usr/bin` paths. Projects are immediate directories below `/workspace`.

## Standardized fleet lifecycle

From the repository root, the supported top-level interface is:

```bash
./Scripts/manage-worker.sh configure       # once per Mac
./Scripts/manage-worker.sh provision 3
./Scripts/manage-worker.sh reconcile all
./Scripts/manage-worker.sh verify all
./Scripts/manage-worker.sh retire 3
```

`worker-baseline.example.env` documents the standardizable provider, host,
network, runtime, and CLI state. Copy it to the ignored
`worker-baseline.local.env` before using lifecycle commands.
`install-worker-host.sh` applies that host state idempotently;
`install-worker.sh` applies the application state. Tagged numeric Tailscale
workers are discovered automatically by Prometheus. Worker-specific addresses,
host keys, Tailscale identities, UUIDs, provider credentials, project checkouts,
and repository deploy keys remain local and unique.

`manage-worker.sh verify` also compares the deployed session helper and MCP
digests with the current checkout, checks their root ownership and mode, runs
Codex's required bubblewrap user/network namespace probe, schedules or
completes a shared app-server rotation after terminals have drained, and
rejects a worker whose restart remains pending or whose live app-server lacks
the managed safe `PATH`.

The shared operator **public** key and its fingerprint are intentionally the
same on every worker. Private machine and project identities must never be
copied between workers.

## Application-only bootstrap

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
architecture. It sends this directory's application installer and configuration
to the host. Use it directly only when the provider and host lifecycle is
already managed; the top-level lifecycle command also provisions Hetzner,
Tailscale, firewalls, Docker, monitoring, shared keys, and host OpenSSH
hardening.

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
- installs the explicit OS dependencies, the current Codex standalone release,
  and Claude from its signed latest apt channel, exposing `/usr/bin/codex` and
  `/usr/bin/claude` without using npm;
- installs the session helper and stdio MCP as root-owned mode `0755`, installs
  the root-owned `terminal-relay-session-restore@.service` template, enables its
  instance for `terminal-relay`, and installs the worker-wide guidance as the
  unprivileged account;
- installs and enables the root-owned `terminal-relay-agent-update.timer`,
  which updates only Claude Code and Codex after boot and four times daily.

After remote readiness checks, the local script reconnects as `terminal-relay`.
It runs `codex login --device-auth` and `claude auth login` interactively only
when their status checks show that authentication is missing. Both checks must
pass before the script writes a mode-`0600`, one-time local proof and opens the
generated registration URL in Terminal Relay. The app consumes that proof before
it accepts the externally invokable URL.
Replaying bootstrap reuses the stable UUID and updates one app profile; it does
not duplicate the worker or replace valid credentials.

The managed server surface is `/etc/terminal-relay`, `/home/terminal-relay`,
`/workspace`, the two agent executable paths, the session helper and MCP, the
systemd restore unit, the automatic updater and timer, and the guidance files
beneath the worker's home directory. A changed managed file gets a sibling
`.backup.<UTC-timestamp>` copy (with a numeric suffix when needed), and an
install failure restores files changed during that run. The UUID and installer
marker intentionally remain after a partial failure. To recover from an
interruption, rerun the exact bootstrap command so it resumes the same worker
identity. If preflight instead reports an unexpected existing
user, path, or workspace content, inspect and resolve that conflict rather than
deleting it blindly; the installer deliberately leaves the root SSH recovery
route intact.

## Automatic agent updates

Each worker updates its own agent CLIs without the Mac or an interactive agent
session. `terminal-relay-agent-update.timer` runs 15 minutes after boot and at
02:00, 08:00, 14:00, and 20:00 UTC with up to 30 minutes of randomized delay.
The root-owned updater:

- upgrades only `claude-code` from Anthropic's signed `latest` apt channel;
- runs `codex update` against the root-owned standalone installation with
  `CODEX_NON_INTERACTIVE=1`;
- serializes itself with the application installer and reports failures through
  the service exit status and journal;
- atomically publishes a root-owned mode-`0644` last-run record containing only
  the UTC timestamp, overall success or failure, and sanitized installed Codex
  and Claude version strings.

An already-running Claude or Codex process continues with the version it
started. The next agent launch uses the updated executable. Inspect the schedule
and the last run as root with:

```bash
systemctl list-timers terminal-relay-agent-update.timer
systemctl status terminal-relay-agent-update.service
journalctl -u terminal-relay-agent-update.service
/usr/local/bin/terminal-relay-session update-status
```

`update-status` is safe for the unprivileged application account. A failed
update does not disable either agent: macOS and iOS show a dismissible warning
with the installed versions the next time they refresh the worker, and the timer
retries automatically. The response contains no package-manager output,
repository details, credentials, host data, or terminal contents.

## Install or update the session runtime

From the repository root, install the session helper, MCP, and restore service
with the application SSH target and an optional privileged SSH target:

```bash
./Scripts/install-worker-session-helper.sh \
  terminal-relay-worker-N \
  root@terminal-relay-worker-N
```

The installer verifies the application account, systemd, exact
`/usr/bin/tmux`, `/usr/bin/flock`, and `/usr/bin/python3` pidfd support; verifies
that the admin connection reaches the same hostname and machine ID; and rechecks
both identity values inside the actual install SSH connection before any managed
write. It then uses either the root account or non-interactive `sudo`. The full
inspect, backup, stage, atomic rename, daemon reload, unit verification, service
enablement, and automatic-restore path holds the root-owned
`/run/lock/terminal-relay-session-helper.lock`. Differing helper and unit files
are retained as timestamped backups, while the MCP is staged, atomically renamed,
and verified in place. A failed install restores the helper, unit, and prior
service enabled/active state. The printed rollback takes the same lock, rechecks
worker identity, refuses symlinks, and requires installed helper and unit
SHA-256 digests and inode states to still match this deployment, so it cannot
overwrite or delete a later deployment. Replacing the helper or MCP also
schedules the shared Codex app-server to restart after active Codex terminals
drain.

Run the isolated local helper coverage before installation:

```bash
./Server/Tests/terminal-relay-session-tests.sh
./Server/Tests/terminal-relay-mcp-tests.sh
```

The test owns a unique tmux socket label, temporary workspace, state directory,
fake boot ID, stub agents, a real `flock(2)` adapter, and an isolated
process-identity signal adapter. It covers concurrent starts, multi-client
reattach, stale instance rejection, exact Stop, normal exit, same-UUID Codex and
Claude recovery, concurrent restore, corrupt state, same-boot death, and actual
agent-lock release. The MCP suite covers its handshake, seven-tool allowlist,
annotations, helper delegation, framing, input/output/time bounds, and error
redaction. Cleanup targets only private temporary resources.

## Version 1 command contract

Machine-readable discovery responses begin with this marker:

```text
__TERMINAL_RELAY_SESSION_V1__
```

The commands are:

```text
terminal-relay-session list-projects
terminal-relay-session status
terminal-relay-session update-status
terminal-relay-session restore
terminal-relay-session start <codex|claude> <repository> [agent arguments...]
terminal-relay-session attach <codex|claude> <repository> [agent arguments...]
terminal-relay-session reattach <codex|claude> <repository> <instance-uuid>
terminal-relay-session stop <codex|claude> <repository> <instance-uuid>
terminal-relay-session threads <repository> <active|archived> [cursor]
terminal-relay-session thread-read <repository> <thread-uuid>
terminal-relay-session thread-create <repository>
terminal-relay-session thread-resume <repository> <thread-uuid> [Codex arguments...]
terminal-relay-session thread-rename <repository> <thread-uuid> <name>
terminal-relay-session thread-archive <repository> <thread-uuid>
terminal-relay-session thread-unarchive <repository> <thread-uuid>
```

`list-projects` emits sorted `project|<repository>` records. Names must match
`^[A-Za-z0-9._-]+$`, contain at most 100 characters, and name real immediate
directories (not symlinks) below `/workspace`.

The V1 parser contract retains the original five-field record for older clients.
Current workers emit one extended record for each active agent:

```text
session|<codex|claude>|<repository>|<attached-client-count>|<instance-uuid>|<activity-epoch>|<hex-UTF-8-title>|<0|1|empty-working>|<provider-thread-uuid>
```

The relay instance UUID is a new immutable terminal identity on every launch.
The provider thread UUID is the persisted conversation identity. For Claude
they are currently the same; for Codex they are deliberately separate.

`update-status` begins with a separate versioned marker and emits at most one
record:

```text
__TERMINAL_RELAY_AGENT_UPDATE_V1__
update|<UTC-epoch-seconds>|<success|failure>|<codex-version>|<claude-version>
```

A marker with no record means that no update status is available yet. The
helper accepts only the fixed root-owned status path, rejects symlinks,
unexpected ownership or permissions, malformed timestamps, and non-version
fields, and exits `70` for malformed state.

The instance is a canonical lowercase UUID and changes on every new agent
launch. `start` is the non-PTY create operation used by apps. It creates an
independent UUID-scoped terminal and returns the marker followed by that
launch's extended session record.

`reattach` never creates. Under the same lock it requires an exact tool,
repository, and instance match, then attaches to the tmux session whose name
contains that immutable UUID. An absent, ended, or replaced launch exits `75`,
including if replacement occurs between lock release and the tmux client exec.
Apps therefore use `start` followed by exact `reattach` rather than a
status-then-create-capable attach sequence.

`attach` remains create-capable for legacy clients. Its older per-provider slot
semantics are retained for compatibility; new clients use `start` followed by
exact `reattach`.

Thread catalog responses use a separate marker followed by one bounded JSON
object:

```text
__TERMINAL_RELAY_THREADS_V1__
{"threads":[{"provider":"codex","threadID":"<uuid>","title":"<optional>","updatedAt":0,"archived":false,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
```

`threads` pages Codex's app-server catalog and filters it by the exact canonical
directory `/workspace/<repository>`. Because Codex intentionally omits a
newly-created thread until it has a non-empty preview, the first page also reads
only that thread's ID, directory, title, activity time, archive flag, and source
from Codex's worker-local metadata index; it never selects preview, prompt, or
turn content. `thread-read` requests metadata with turns excluded. Create,
resume, rename, archive, and unarchive accept only canonical UUIDs and real,
non-symlinked project directories. Resume starts
`codex resume <thread-uuid>` in a new relay terminal. Rename/archive/unarchive
reject a thread that already has a live relay instance. No command returns
turns, prompts, account data, or arbitrary app-server responses.

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

Each successful initial launch writes a mode-`0600` restart intent below the
runtime user's mode-`0700` `~/.local/state/terminal-relay` directory. The record
contains data only: repository, Terminal Relay UUID, provider thread UUID, boot
ID, and the original argument array. `restore` holds the same instance locks
and acts only on a valid intent from an earlier boot. It recreates the same
UUID-named tmux session, starts Claude with `--resume <uuid>`, or starts Codex
with `resume <provider-thread-uuid>` from the recorded repository. A legacy
intent with no Codex provider ID retains the old `resume --last` fallback.
Caller-supplied lifecycle flags are rejected. A normal CLI exit, failed initial
launch, or exact `stop` removes only its matching intent; shutdown retains it.
The enabled
`terminal-relay-session-restore@<user>.service` runs this path after filesystems
and network readiness, without SSH, the Mac, or iPhone.

Provider recovery depends on local transcript data remaining on the worker.
Claude is bound to the relay UUID and Codex is bound to its recorded provider
thread UUID. Reboot recovery is not disk-loss recovery: back up
`~/.codex/sessions` and `~/.claude/projects` separately if host-loss recovery is
required.

Inspect or retry the boot service as an administrator (substitute the actual
application user for `terminal-relay`):

```bash
systemctl status terminal-relay-session-restore@terminal-relay.service
journalctl -b -u terminal-relay-session-restore@terminal-relay.service
systemctl restart terminal-relay-session-restore@terminal-relay.service
```

The dedicated tmux socket label is `terminal-relay`. Sessions are uniquely named
`terminal-relay-<tool>-<instance-uuid>`, preventing a stale attach handoff from
targeting a replacement. Its status bar is disabled.
Pane titles are emitted to attached terminals so Codex title/run-state updates
continue to reach SwiftTerm. tmux does not forward Claude's plain OSC 9;4
progress sequence in this relay path (confirmed with tmux 3.6a even when
passthrough is enabled), so that progress-only signal cannot cross this helper;
the agent session and ordinary terminal output are not affected. Repository
metadata, restart intents, and the control and agent locks live below
`~/.local/state/terminal-relay`. New terminals use UUID-scoped locks, so
multiple Codex and Claude processes can run concurrently without weakening
exact-instance stop or stale-attach checks. Legacy create-capable attachment
keeps its provider-scoped lock.

The shared Codex app server adds the built-in `terminal_relay` MCP without
changing Codex's existing configuration policy for other servers. Managed
Claude launches receive the same fixed
`/usr/local/bin/terminal-relay-mcp` through strict MCP configuration. The MCP is
a dependency-free Python stdio server and exposes exactly `list_projects`,
`list_threads`, `start_thread`, `resume_thread`, `rename_thread`,
`archive_thread`, and `unarchive_thread`. It invokes only the fixed session
helper under a safe `PATH`, enforces canonical inputs plus 30-second and 1 MiB
bounds, redacts helper stderr, and has no listener, shell, transcript access,
terminal input, permanent deletion, or cross-worker capability. Claude's strict
launch policy prevents unrequested servers.

For the isolated integration test only, a helper invoked from a path other than
`/usr/local/bin/terminal-relay-session` accepts these settings:

- `TERMINAL_RELAY_TEST_MODE=1` (required)
- `TERMINAL_RELAY_TEST_TMUX_PATH`
- `TERMINAL_RELAY_TEST_TMUX_SOCKET`
- `TERMINAL_RELAY_TEST_WORKSPACE_ROOT`
- `TERMINAL_RELAY_TEST_RUNTIME_ROOT`
- `TERMINAL_RELAY_TEST_BOOT_ID_PATH`
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
`./Scripts/sync-worker-guidance.sh ssh-target [...]`. The worker installer
updates `~/AGENTS.md`,
`~/CLAUDE.md`, `~/.codex/AGENTS.md`, and `~/.claude/CLAUDE.md`, preserving each
differing file as a timestamped adjacent backup.
