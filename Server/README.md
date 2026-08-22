# Dedicated worker helper

`terminal-relay-session` is the root-owned `/usr/local/bin/terminal-relay-session`
entry point used by Terminal Relay clients. `terminal-relay-mcp` is the
root-owned `/usr/local/bin/terminal-relay-mcp` stdio MCP exposed inside managed
Codex and Claude terminals. The worker needs Bash, `flock`, `/usr/bin/python3`
with Linux pidfd support, `python3-venv`, and tmux, plus Codex and Claude at
their standard `/usr/bin` paths. Projects are immediate directories below
`/workspace`. Claude catalog operations run through a separately pinned,
root-owned official Claude Agent SDK environment.

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

The host baseline also refreshes four public-safe node-exporter textfile gauges
for the installed Tailscale version, the fleet security minimum, Tailscale
auto-update state, and the standard Ubuntu reboot-required marker. It does not
scan worker projects, terminal sessions, or host indicators of compromise.

`manage-worker.sh verify` also compares the deployed session helper, MCP, and
Claude session adapter digests with the current checkout, checks their root
ownership and mode, verifies the pinned SDK version, runs Codex's required
bubblewrap user/network namespace probe, schedules or completes a shared
app-server rotation after terminals have drained, and rejects a worker whose
restart remains pending or whose live app-server lacks the managed safe `PATH`.

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
- installs the session helper, stdio MCP, and Claude session adapter as
  root-owned mode `0755`; builds the adapter's exact pinned official Agent SDK
  environment below `/opt/terminal-relay/claude-session-sdk`; installs the
  root-owned `terminal-relay-session-restore@.service` template; enables its
  instance for `terminal-relay`; and installs the worker-wide guidance as the
  unprivileged account;
- installs and enables the root-owned `terminal-relay-agent-update.timer`,
  which updates only Claude Code and Codex after boot and four times daily; and
- installs the root-owned signed-runtime updater, stable release public key,
  periodic timer, fixed request path, sanitized status file, and paired-mobile
  forced-command gateway.

After remote readiness checks, the local script reconnects as `terminal-relay`.
It runs `codex login --device-auth` and `claude auth login` interactively only
when their status checks show that authentication is missing. Both checks must
pass before the script writes a mode-`0600`, one-time local proof and opens the
generated registration URL in Terminal Relay. The app consumes that proof before
it accepts the externally invokable URL.
Replaying bootstrap reuses the stable UUID and updates one app profile; it does
not duplicate the worker or replace valid credentials.

The managed server surface is `/etc/terminal-relay`, `/home/terminal-relay`,
`/workspace`, the two agent executable paths, the session helper, MCP, Claude
session adapter and SDK environment, the systemd restore unit, the automatic
updater and timer, and the guidance files beneath the worker's home directory.
A changed managed file gets a sibling
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

## Automatic worker runtime updates

`Server/worker-runtime-files.txt` is the single payload allowlist used by
bootstrap, reconciliation, helper-only installation, App Review, verification,
and release packaging. A runtime manifest names the exact destination, mode,
SHA-256 digest, protocol range, and capabilities for every helper, adapter, SDK
lock, unit, gateway, updater, and public key. Releases use the producing commit
timestamp as a monotonically increasing runtime version.

`terminal-relay-runtime-update.timer` checks the one stable HTTPS feed five
minutes after boot and at 01:15, 07:15, 13:15, and 19:15 UTC, with a bounded
random delay. A compatible macOS or paired-mobile client can also call the
typed `runtime-update-request` helper operation. That operation only touches a
root-owned path trigger; it cannot select a URL, version, file, systemd unit, or
network command. `terminal-relay-runtime-update.path` converts the trigger into
the same serialized root service.

Every change to `Server/worker-runtime-files.txt` or one of its payloads on
`main` automatically runs the signed stable publication workflow. Production
bootstrap, fleet reconciliation, App Review provisioning, and helper-only
installation first verify the published signature, runtime version, allowlist
metadata, and every local payload digest. They stop without modifying a worker
while publication is pending, so an operator checkout cannot move a production
worker ahead of the stable feed.

The root updater accepts no arguments. It downloads only the compiled-in feed,
uses bounded HTTPS timeouts and retries, verifies the Ed25519 manifest
signature, rejects non-monotonic versions or any payload outside the exact
allowlist, then verifies the archive digest, entry type, ownership, mode, and
per-file digest before installation. It prepares the pinned SDK without
switching the live link, takes the deployment and agent-update locks, installs
through atomic renames, and rolls back files, the installed manifest, and SDK
link on failure. It does not read or write `/workspace`, provider credentials
or histories, relay metadata, restart intents, or tmux processes. Restart
markers are recorded for every registered Codex profile, then each profile's
lazy app-server rotates after its active Codex tasks drain.

The unprivileged helper exposes only:

```bash
terminal-relay-session runtime-info
terminal-relay-session runtime-update-status
terminal-relay-session runtime-update-request
```

`runtime-info` reports the installed version, supported client-protocol range,
and sorted capabilities, including the required `file-attachments-v1` feature.
`runtime-update-status` reports only a timestamp,
checking/success/failure, installed version, target version, and a safe failure
code. Clients request one immediate check when a reported protocol or required
capability is incompatible, poll with bounded backoff, refresh worker catalogs
when compatible, and otherwise leave other workers and existing terminals
available. The timer retries failures automatically.

Workers created before this updater need one
`./Scripts/manage-worker.sh reconcile all` (or their original application-only
bootstrap command). Future stable runtime changes then arrive unattended. App
binaries remain separate: Sparkle updates macOS and the App Store updates
iPhone/iPad.

## Provider account profiles

The account-aware Mac client uses the worker-owned registry below
`~/.local/share/terminal-relay/provider-accounts-v1`. A profile contains only a
worker-issued UUID, provider, label, status, and storage kind. Credentials stay
in provider-native storage. The worker derives every path; clients cannot
provide `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, socket, or credential paths.

The registry imports the existing default Codex and Claude profiles in place.
An isolated Codex profile receives its own `CODEX_HOME`, stable app-server Unix
socket, and lazy tmux process. An isolated Claude profile receives its own
`CLAUDE_CONFIG_DIR`, which is passed to login, status, history, Agent SDK, live
broker, and restore operations. Adding a second profile for either provider
writes the permanent `activated` marker only after the Mac confirms that
existing history belongs to the imported current profile. Activation is
refused while an accountless legacy terminal or chat relay is live. After
activation, accountless legacy commands return `upgradeRequired` before
provider access.

```text
terminal-relay-session provider-accounts-v1 [codex|claude]
terminal-relay-session provider-account-create-v1 <codex|claude> <label>
terminal-relay-session provider-account-login-v1 <codex|claude> <account-id>
terminal-relay-session provider-account-status-v1 <codex|claude> <account-id>
terminal-relay-session provider-account-rename-v1 <codex|claude> <account-id> <label>
```

Profiles are a deterministic routing boundary for a single trusted owner. They
are not hostile-tenant isolation from code with full access as the same worker
Unix user.

## Native structured chat

Supported clients negotiate native chat before starting or resuming an agent.
The worker exposes these fixed helper operations:

```text
terminal-relay-session chat-capabilities-v2 <codex|claude> <account-id> <repository>
terminal-relay-session chat-start-v2 <codex|claude> <account-id> <repository> [provider-thread-id] [agent arguments...]
terminal-relay-session chat-attach-v2 <codex|claude> <account-id> <repository> <relay-id>
terminal-relay-session chat-stop-v2 <codex|claude> <account-id> <repository> <relay-id>
terminal-relay-session chat-attachment-upload-v2 <codex|claude> <account-id> <repository> <relay-id> <request-id> <attachment-id> <extension> <byte-count>
terminal-relay-session chat-attachment-delete-v2 <codex|claude> <account-id> <repository> <relay-id> <request-id>
```

`chat-start-v2` launches one `terminal-relay-chat` broker under the selected
account route and provider-thread lock. The broker owns the provider connection
and listens only on a mode-`0600` Unix socket. `chat-attach-v2`
opens a non-PTY, bidirectional NDJSON stream over the authenticated SSH
connection. Disconnecting that stream leaves the broker and provider running;
`chat-stop-v2` accepts only the exact account and relay UUID and ends that instance for all
attached clients.

Workers advertising `file-attachments-v1` accept attachment bytes only on the
typed upload helper's SSH standard input. Uploads are atomically placed in an
owner-only, relay- and request-scoped runtime directory; original filenames
are metadata, not paths. The broker validates identity, regular-file type,
ownership, mode, and byte counts before starting the provider turn. It removes the
request directory on every terminal turn result, rejected submission, explicit
client cleanup, broker startup or shutdown, and through a bounded orphan
sweep. Attachment contents and paths are not logged or persisted in the
conversation snapshot or replay window.

Codex chat uses the selected profile's worker-local app-server and its v2
history and turn methods. Claude chat uses the selected profile's pinned
official Agent SDK environment. Provider
history remains authoritative. The broker retains only a bounded in-memory
snapshot, replay window, and unresolved live interactions; it has no TCP
listener or transcript database. See
[`docs/chat-protocol.md`](../docs/chat-protocol.md) for the versioned contract,
limits, replay behavior, interaction mapping, and repository-preview boundary.

If either adapter is unavailable or an older worker does not advertise chat,
new and resumed native conversations fail closed until the worker is updated.
The clients can still display an already-running legacy PTY session, but they
never migrate an active chat into one or run both modes against one provider
thread.

## Install or update the session runtime

From the repository root, install the session helper, MCP, Claude session
adapter and pinned SDK, and restore service with the application SSH target and
an optional privileged SSH target:

```bash
./Scripts/install-worker-session-helper.sh \
  terminal-relay-worker-N \
  root@terminal-relay-worker-N
```

The installer verifies the application account, systemd, exact
`/usr/bin/tmux`, `/usr/bin/flock`, and `/usr/bin/python3` pidfd support; verifies
that the admin connection reaches the same hostname and machine ID; and rechecks
both identity values inside the actual install SSH connection before any managed
write. It then uses either the root account or non-interactive `sudo`, installs
`python3-venv` when needed, builds a requirements-hash-named root-owned SDK
environment, verifies the adapter as the application user, and atomically
switches its `current` link. The inspect, stage, atomic rename, daemon reload,
unit verification, and service enablement path holds the root-owned
`/run/lock/terminal-relay-session-helper.lock`. By default it leaves no retained
host copies. If an operator explicitly requests `--retain-backups`, differing
helper and unit files are retained as timestamped backups and the installer
prints a guarded rollback command. The MCP and Claude adapter are always staged,
atomically renamed, and verified in place. Replacing the helper or MCP also
schedules every registered Codex profile's app-server to restart after its
active tasks drain. Both the full worker installer and this helper-only installer require the
installed runtime to advertise `file-attachments-v1` before succeeding.

Run the isolated local helper coverage before installation:

```bash
./Server/Tests/terminal-relay-session-tests.sh
./Server/Tests/terminal-relay-mcp-tests.sh
./Server/Tests/terminal-relay-claude-sessions-tests.py
```

The tests own a unique tmux socket label, temporary workspace, state directory,
fake boot ID, synthetic provider metadata, stub agents, a real `flock(2)`
adapter, and an isolated process-identity signal adapter. They cover concurrent
starts and exact Claude resume rejection, multi-client reattach, stale instance
rejection, relay/provider UUID separation, resume-safe arguments, exact Stop,
normal exit, reboot recovery, malformed metadata, repository and worktree
scope, pagination, rename, archive persistence, activity states, and output
redaction. The MCP suite covers its handshake, seven-tool allowlist,
provider-aware helper delegation, framing, input/output/time bounds, and error
redaction. Cleanup targets only private temporary resources and never reads a
real transcript.

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
terminal-relay-session threads-v2 <codex|claude> <repository> <open|archived> [cursor]
terminal-relay-session thread-read-v2 <codex|claude> <repository> <thread-uuid>
terminal-relay-session thread-resume-v2 <codex|claude> <repository> <thread-uuid> [agent arguments...]
terminal-relay-session thread-rename-v2 <codex|claude> <repository> <thread-uuid> <name>
terminal-relay-session thread-archive-v2 <codex|claude> <repository> <thread-uuid>
terminal-relay-session thread-unarchive-v2 <codex|claude> <repository> <thread-uuid>
terminal-relay-session status-v2
terminal-relay-session start-v2 <codex|claude> <account-id> <repository> [agent arguments...]
terminal-relay-session reattach-v2 <codex|claude> <account-id> <repository> <instance-uuid>
terminal-relay-session stop-v2 <codex|claude> <account-id> <repository> <instance-uuid>
terminal-relay-session threads-v3 <codex|claude> <account-id> <repository> <open|archived> [cursor]
terminal-relay-session thread-create-v2 <account-id> <repository>
terminal-relay-session thread-read-v3 <codex|claude> <account-id> <repository> <thread-uuid>
terminal-relay-session thread-resume-v3 <codex|claude> <account-id> <repository> <thread-uuid> [agent arguments...]
terminal-relay-session thread-rename-v3 <codex|claude> <account-id> <repository> <thread-uuid> <name>
terminal-relay-session thread-archive-v3 <codex|claude> <account-id> <repository> <thread-uuid>
terminal-relay-session thread-unarchive-v3 <codex|claude> <account-id> <repository> <thread-uuid>
```

`list-projects` emits sorted `project|<repository>` records. Names must match
`^[A-Za-z0-9._-]+$`, contain at most 100 characters, and name real immediate
directories (not symlinks) below `/workspace`.

The V1 parser contract remains available only before account activation. The
account-aware status marker is `__TERMINAL_RELAY_SESSION_V2__`; each live row is:

```text
session|<codex|claude>|<account-id>|<repository>|<attached-client-count>|<instance-uuid>|<activity-epoch>|<hex-UTF-8-title>|<0|1|empty-working>|<provider-thread-uuid>|<terminal|chat>
```

The activity epoch is seconds since the Unix epoch, with 0 meaning unknown.
Terminal records take it from tmux window activity; chat records report the
broker's last conversation event, which the broker persists into its state
file on a 30-second throttle and re-seeds across restarts. The status
listing gathers every live broker's identity and activity in a single
`terminal-relay-chat inspect-status` invocation.

Account-aware status also migrates pre-account leftovers instead of listing
them. When the scan finds a live accountless legacy chat broker, or the legacy
shared Codex app-server still runs with a pending restart marker, `status-v2`
schedules a detached one-shot migration that stops each legacy broker with
`chat-stop-v1` semantics (the broker exits, its restart intent is removed, the
conversation stays resumable as a thread) and then — only once no accountless
Codex terminal or chat relay is live — retires the legacy shared Codex
app-server and its restart marker, releasing the thread-writer locks that
otherwise block account-pinned resumes of threads that server had opened.

The relay instance UUID is a new immutable terminal identity on every launch.
The provider thread UUID is the persisted conversation identity. Current app
starts and V2 resumes deliberately keep them separate for both providers: a
new or resumed Claude conversation is started with a provider UUID distinct
from its relay instance UUID. Legacy create-capable `attach` retains its
historical identity behavior for installed clients.

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

Current clients use the provider-aware V2 commands. Their catalog begins with
`__TERMINAL_RELAY_THREADS_V2__` and adds `activityState`,
`activeInstanceToken`, and activity-derived capabilities:

```json
{"threads":[{"provider":"claude","threadID":"00000000-0000-4000-8000-000000000000","title":"Example","updatedAt":0,"archived":false,"activityState":"inactive","activeInstanceToken":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
```

The activity state is `inactive`, `relay-active`, `external-active`, or
`unknown`. Only a proven-inactive row can be resumed or mutated. An active
instance token is returned only for a live Terminal Relay terminal. A
relay-active chat row's `updatedAt` is raised to the live broker's
last-event time when that outranks the provider catalog's own activity
time, which lags (or reads 0) while the broker holds the conversation open.

Claude discovery, metadata read, and rename use the exact pinned official
Claude Agent SDK. The adapter asks Claude Code for its agent registry, validates
the reported PID against the local process lifetime, and combines that result
with relay state. It accepts only canonical provider UUIDs whose provider
working directory is the selected `/workspace/<repository>` or a Git worktree
sharing that repository's common directory. Missing, malformed, out-of-scope,
or corrupt metadata is not repaired: list skips it, while an exact read or
mutation fails closed. The adapter emits only provider UUID, display title,
last activity time, archive state, and activity state. The official SDK derives
those fields from Claude's local provider history; Terminal Relay never calls
the message-history API, parses transcript records itself, or returns transcript
items.

`thread-resume-v2 claude` creates a fresh relay UUID and launches
`claude --resume <provider-uuid>`. Model and effort launch overrides are removed
so Claude restores its conversation state; the fixed Terminal Relay MCP,
settings, and configured permission mode are reapplied. Provider/session locks
serialize the final activity check with resume, rename, archive, and unarchive
across app and MCP clients.

Claude rename is provider-native: the SDK appends a custom-title entry to the
provider transcript, the newest title wins, and no transcript rewrite occurs.
Claude archive is Terminal Relay-owned only: a mode-`0600` marker below the
user's mode-`0700` relay state directory hides the row from the open catalog. It
does not delete, retain, tag, move, or modify the provider transcript, and it
cannot prevent a direct Claude Code resume outside Terminal Relay. Unarchive
removes only that marker.

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
runtime user's mode-`0700` `~/.local/state/terminal-relay` directory. The
account-aware record contains data only: provider, account UUID, repository,
Terminal Relay UUID, provider thread UUID, boot ID, and the resume-safe
argument array. `restore` holds the same instance and
provider-account-thread locks and acts only on a valid intent from an earlier boot. It
recreates the same UUID-named tmux session, starts Claude with
`--resume <provider-thread-uuid>`, or starts Codex with
`resume <provider-thread-uuid>` from the recorded repository. Accountless
legacy intents are not promoted after activation.
Caller-supplied lifecycle flags are rejected. A normal CLI exit, failed initial
launch, or exact `stop` removes only its matching intent; shutdown retains it.
The enabled
`terminal-relay-session-restore@<user>.service` runs this path after filesystems
and network readiness, without SSH, the Mac, or iPhone.

Provider recovery depends on local transcript data remaining on the worker.
Both providers are bound to their recorded provider thread UUID, independently
of the relay UUID. Reboot recovery is not disk-loss recovery, and Terminal
Relay does not copy provider history between workers. Claude's own retention
and cleanup policy still determines whether an inactive UUID remains resumable.
Multi-device handoff works when the clients reach the same worker; worker
replacement or cross-worker migration requires a separate, operator-owned
provider-data migration.

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

Before multi-account activation, the shared Codex app server adds the built-in
`terminal_relay` MCP without changing Codex's existing configuration policy for other servers. Managed
Claude launches receive the same fixed
`/usr/local/bin/terminal-relay-mcp` through strict MCP configuration. The MCP is
a dependency-free Python stdio server and exposes exactly `list_projects`,
`list_threads`, `start_thread`, `resume_thread`, `rename_thread`,
`archive_thread`, and `unarchive_thread`. It invokes only the fixed session
helper under a safe `PATH`. `start_thread` remains Codex-only; list, resume,
rename, archive, and unarchive are provider-aware. The server enforces canonical
inputs plus 30-second and 1 MiB bounds, redacts helper stderr, and has no
listener, shell, transcript access, terminal input, permanent deletion, or
cross-worker capability. Claude's strict launch policy prevents unrequested
servers.

After activation, the ambient MCP advertises no tools and returns
`upgradeRequired` without invoking the session helper. A public account UUID or
model-controlled environment variable is not accepted as authorization; a
future account-aware MCP requires a host-created task-scoped capability.

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
- `TERMINAL_RELAY_TEST_CLAUDE_SESSIONS_PYTHON_PATH`
- `TERMINAL_RELAY_TEST_CLAUDE_SESSIONS_ADAPTER_PATH`
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
