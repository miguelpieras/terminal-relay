# Terminal Relay

Terminal Relay is a native macOS workspace for Codex CLI and Claude Code sessions that run on remote servers. The app only starts the system SSH client locally; the coding agents, repositories, and account credentials stay on each server.

## What it does

- Keeps a project-first list of remote workspaces, each assigned to a reusable worker profile.
- Lists repositories from the authenticated GitHub account on the Mac and can create private repositories under `miguelpieras`.
- Uses the same remote path for every worker: `/workspace/<repository-name>`.
- Opens embedded, full interactive SSH terminals for Codex CLI and Claude Code.
- Starts those sessions without project or worker MCP servers.
- Allows one Codex session and one Claude session per worker at the same time, even when that worker hosts several projects.
- Uses the existing OpenSSH config, agent, known-hosts checks, and optional identity files on the Mac.
- Persists connection details and account labels, but never passwords, API keys,
  terminal output, or a local copy of running-session state. Live sessions are
  discovered from the worker.

The first launch includes the dedicated **Terminal Relay Worker 1** profile. Its `terminal-relay-worker-1` SSH alias uses the existing private Tailscale route. The project list starts empty; Terminal Relay never creates or opens a generic Workspace project.

The current worker-to-host mapping, access commands, trusted fingerprints, and
recovery details are documented in [`docs/workers.md`](docs/workers.md).

Each project expands into thin session rows in the sidebar. An animated spinner means the agent is working, a static colored dot means it is open and ready, and a gray outlined dot means it has exited. Exited sessions remain as history until closed, so one project can accumulate many Codex and Claude rows without implying that more than one of either tool is active on a worker.

That worker also has the small root-owned `terminal-relay-session` launcher from
`Server/`. It keeps Codex and Claude inside stable worker-side `tmux` sessions
and retains the host-local lock per tool, so the server itself allows one Codex
and one Claude process at a time across Mac and iPhone clients. A worker-side
systemd service restores active sessions after a reboot; neither client nor the
Mac needs to be online.

The concurrency limit applies to sessions started by Terminal Relay. It cannot detect an agent started independently in another SSH client.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- `xcodegen` (`brew install xcodegen`)
- Working SSH access to each configured server
- GitHub CLI authenticated as `miguelpieras` on the Mac (`gh auth login`)
- For manually configured legacy workers, `codex` and/or `claude` available to
  the remote account's login shell; bootstrap installs both on a fresh worker
- Apple's Metal toolchain component, used to compile SwiftTerm's optional renderer (`xcodebuild -downloadComponent MetalToolchain`)

## Build and install

```sh
cd ~/dev/terminal-relay
./Scripts/build-and-install.sh
```

This required post-change command regenerates the Xcode project, runs all tests, creates a Release build, ad-hoc signs it, installs it at `/Applications/Terminal Relay.app`, and relaunches it. The Dock item continues to point at that stable path as builds are replaced.

To work in Xcode, run `open TerminalRelay.xcodeproj`.

The app target intentionally does not enable App Sandbox because its embedded terminal needs to launch `/usr/bin/ssh` inside a pseudo-terminal.

## Bootstrap a worker

The supported version 1 starting point is a fresh Hetzner server running Ubuntu
24.04 on amd64 with at least 4 GB of RAM. It must be reachable as `root` with an
SSH key. `/Applications/Terminal Relay.app` must already be installed on the
Mac, and the local GitHub CLI must be authenticated (`gh auth status`).

From the repository root, run:

```bash
./Scripts/bootstrap-worker.sh [--identity PATH] [--port N] root@host
```

For example:

```bash
./Scripts/bootstrap-worker.sh root@203.0.113.10
./Scripts/bootstrap-worker.sh --identity ~/.ssh/hetzner --port 2222 root@203.0.113.10
```

`host` may be an IP address, DNS name, or SSH config alias.

The script keeps normal OpenSSH known-hosts verification. Before changing the
server, it shows the resolved SSH destination, trusted host-key fingerprint,
current remote hostname, OS, and architecture in one exact-target confirmation.
It then creates an unprivileged, password-locked `terminal-relay` account, gives
it the bootstrap account's authorized keys, and assigns a stable generated UUID,
hostname, and display name. A preassigned hostname such as
`terminal-relay-worker-2` is retained as the friendly app name **Terminal Relay
Worker 2**; otherwise the display name uses the UUID's short form. Root SSH
access and `sshd` configuration are left unchanged.

Codex and Claude are installed from their official distributions at
`/usr/bin/codex` and `/usr/bin/claude`; bootstrap does not install either tool
through npm. After installation, the script reconnects as `terminal-relay`. It
skips account setup when a CLI is already authenticated and otherwise runs
`codex login --device-auth` and `claude auth login` interactively. Registration
in Terminal Relay happens only after both account checks pass, then the script
opens the app through its `com.mpieras.TerminalRelay` bundle identifier. The app
receives connection details and the generated worker identity through a
mode-`0600`, one-time local registration handoff, never CLI credentials.

Re-running the same command is the supported update and recovery path. It reuses
the UUID in `/etc/terminal-relay/worker-id`, hostname, and display name, updates
the existing app profile instead of adding a duplicate, preserves valid
authentication, and makes no change to already-correct managed files. Differing
installer-owned configuration receives timestamped sibling backups, and a failed
install restores the managed files changed during that run. The UUID and
installer marker intentionally remain after a partial failure so the next run
can recover the same worker. If preflight reports an unexpected existing
account, managed path, or non-empty `/workspace`, inspect that conflict instead
of deleting it and retry after resolving it; the unchanged root SSH route
remains available for recovery.

Bootstrap manages `/etc/terminal-relay` (including `worker-id`, `display-name`,
and the `installer-version` marker), `/home/terminal-relay`, `/workspace`, the
agent executables, `/usr/local/bin/terminal-relay-session`, its systemd restore
unit, the worker-wide guidance under the worker's home directory, and the
consumed local registration handoff. Hetzner provisioning and retirement,
Tailscale, firewall or `sshd` hardening, and backup services are outside version
1.

The existing **Terminal Relay Worker 1** predates this flow and remains supported
unchanged. For session-runtime updates or manual guidance synchronization on
that worker, see `Server/README.md`.

When a project is added, Terminal Relay uses the Mac's authenticated `gh` CLI to create or inspect the repository. It generates a dedicated deploy key on the selected worker, grants that key access only to the selected repository, and clones into `/workspace/<repository-name>`. The private key never leaves the worker, the GitHub credential never leaves the Mac, and no credential is stored in the project record or Git remote URL.

## Persistent terminal lifecycle

Each worker can run one Codex and one Claude agent. Opening a terminal starts the
tool in its stable `tmux` session or attaches to the existing session for that
repository. A second Mac or iPhone may attach at the same time. If that tool is
already running for another repository, the worker reports the occupied
repository instead of launching a second process.

**Disconnect**, closing a terminal, losing SSH, backgrounding the iPhone app,
and quitting the Mac app close only that client's attachment. The agent keeps
running on the worker. Terminal Relay polls worker status at launch, when it
returns to the foreground, and while it remains open, then offers **Reconnect**
for detached sessions. **Stop Agent** is the separately confirmed operation that
ends the shared remote agent for every client.

If the worker reboots while an agent is active, its systemd restore service
recreates the `tmux` session with the same Terminal Relay UUID and resumes the
provider conversation from the worker's local CLI transcript. Claude resumes
the exact UUID-bound session. Codex runs `resume --last` from the recorded
repository, so a newer out-of-band Codex session in that same repository can
change which conversation Codex selects. A normal CLI exit or **Stop Agent**
deletes the restart intent, preventing resurrection.

Recovery requires the worker disk and the provider's local session data (for
example `~/.codex/sessions` and `~/.claude/projects`) to survive. It does not
restore a conversation from OpenAI or Anthropic after disk or host loss; those
directories need a separate encrypted off-worker backup for that case.

For a manually managed worker, test and install the current helper with:

```bash
./Server/Tests/terminal-relay-session-tests.sh
./Scripts/install-worker-session-helper.sh \
  terminal-relay-worker-1 \
  root@terminal-relay-worker-1
```

The installer verifies that both SSH targets reach the same machine and that
systemd, `/usr/bin/tmux`, `/usr/bin/flock`, and `/usr/bin/python3` with Linux
pidfd signaling are available. It atomically installs the helper and restore
unit, retains differing files as timestamped backups, enables the per-user
service, and prints one guarded rollback command. Re-run the same installer to
update or recover both managed files. First read the live status record, then
use its repository and instance UUID for an emergency stop:

```bash
ssh terminal-relay-worker-1 /usr/local/bin/terminal-relay-session status
# session|codex|REPOSITORY|ATTACHED_CLIENTS|INSTANCE_UUID
ssh terminal-relay-worker-1 \
  '/usr/local/bin/terminal-relay-session stop codex REPOSITORY INSTANCE_UUID'

# Inspect or retry boot recovery (use the worker's application username).
ssh root@terminal-relay-worker-1 \
  'systemctl status terminal-relay-session-restore@terminal-relay.service'
ssh root@terminal-relay-worker-1 \
  'journalctl -b -u terminal-relay-session-restore@terminal-relay.service'
ssh root@terminal-relay-worker-1 \
  'systemctl restart terminal-relay-session-restore@terminal-relay.service'
```

Use `claude` in place of `codex` for that slot. The UUID check deliberately
refuses a stale stop instead of ending a replacement launch.

Pane titles cross the `tmux` relay, including Codex's title-based working state.
Claude's standalone OSC 9;4 progress signal is stripped by `tmux`, so its
progress-only sidebar animation is unavailable while relayed; the session and
ordinary terminal output are unaffected.

## iPhone client

The iOS 17 app keeps a local worker list and manages each worker's `/workspace`
projects and shared Codex and Claude sessions. Repository creation, Git
operations, deployment, account usage, and worker administration remain
Mac-only. Build and run the **TerminalRelayIOS** scheme from
`TerminalRelay.xcodeproj` on an iPhone with Tailscale installed and connected.

On first launch, the app creates a dedicated Ed25519 key and keeps its private
material in the device Keychain. Copy the displayed public key into the worker
user's `~/.ssh/authorized_keys`. Retrieve the trusted server fingerprint over an
already verified Mac SSH connection, rather than from the iPhone's first network
connection:

```bash
ssh terminal-relay-worker-1 \
  '/usr/bin/ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256'
```

Add each worker with its display name, Tailscale hostname or IP, SSH port,
username, and reported `SHA256:...` fingerprint. Every connection pins the
selected worker's fingerprint and rejects a different host key. Swipe a worker
row to edit or remove it. Worker connection fields are stored locally; one
device-specific public key can be authorized on every worker, while its private
key never leaves Keychain.

A normal handoff is: start or attach on the Mac, disconnect or quit the Mac app,
attach to the same project and tool on iPhone, disconnect the iPhone, then choose
**Reconnect** on the Mac. If iOS loses its Keychain identity, authorize its newly
displayed public key. If the worker host key changes, verify the replacement
through a trusted administrative route before updating the pin. If discovery
fails because the helper is missing or outdated, re-run the helper installer and
retain its printed rollback command.
