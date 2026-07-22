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

Each project expands into thin session rows in the sidebar. An animated spinner means the agent is working, a static colored dot means it is open and ready, and a gray outlined dot means it has exited. Exited sessions remain as history until closed, so one project can accumulate many Codex and Claude rows without implying that more than one of either tool is active on a worker.

That worker also has the small root-owned `terminal-relay-session` launcher from
`Server/`. It keeps Codex and Claude inside stable worker-side `tmux` sessions
and retains the host-local lock per tool, so the server itself allows one Codex
and one Claude process at a time across Mac and iPhone clients.

The concurrency limit applies to sessions started by Terminal Relay. It cannot detect an agent started independently in another SSH client.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- `xcodegen` (`brew install xcodegen`)
- Working SSH access to each configured server
- GitHub CLI authenticated as `miguelpieras` on the Mac (`gh auth login`)
- `codex` and/or `claude` available to a login shell on the remote server
- Apple's Metal toolchain component, used to compile SwiftTerm's optional renderer (`xcodebuild -downloadComponent MetalToolchain`)

## Build and install

```sh
cd ~/dev/terminal-relay
./Scripts/build-and-install.sh
```

This required post-change command regenerates the Xcode project, runs all tests, creates a Release build, ad-hoc signs it, installs it at `/Applications/Terminal Relay.app`, and relaunches it. The Dock item continues to point at that stable path as builds are replaced.

To work in Xcode, run `open TerminalRelay.xcodeproj`.

The app target intentionally does not enable App Sandbox because its embedded terminal needs to launch `/usr/bin/ssh` inside a pseudo-terminal.

## Worker setup

Add a worker with either a normal hostname or an alias from `~/.ssh/config`, then assign projects to it. If the alias already defines the user, port, identity, or proxy, leave the corresponding fields in Terminal Relay at their defaults. Commands run through the remote account's login shell, so shell-managed installations such as `nvm` are available.

Worker-wide Codex and Claude guidance is tracked in `Server/worker-config/`. Run `./Scripts/sync-worker-guidance.sh [ssh-target ...]` to install it, defaulting to `terminal-relay-worker-1` when no target is given. Differing remote files receive timestamped backups before replacement.

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

For a manually managed worker, test and install the current helper with:

```bash
./Server/Tests/terminal-relay-session-tests.sh
./Scripts/install-worker-session-helper.sh \
  terminal-relay-worker-1 \
  root@terminal-relay-worker-1
```

The installer verifies that both SSH targets reach the same machine and that
`/usr/bin/tmux`, `/usr/bin/flock`, and `/usr/bin/python3` with Linux pidfd
signaling are available. It retains a differing installed helper as a
timestamped backup and prints the exact rollback command. Re-run the same
installer to update or recover the helper. First read the live status record,
then use its repository and instance UUID for an emergency stop:

```bash
ssh terminal-relay-worker-1 /usr/local/bin/terminal-relay-session status
# session|codex|REPOSITORY|ATTACHED_CLIENTS|INSTANCE_UUID
ssh terminal-relay-worker-1 \
  '/usr/local/bin/terminal-relay-session stop codex REPOSITORY INSTANCE_UUID'
```

Use `claude` in place of `codex` for that slot. The UUID check deliberately
refuses a stale stop instead of ending a replacement launch.

Pane titles cross the `tmux` relay, including Codex's title-based working state.
Claude's standalone OSC 9;4 progress signal is stripped by `tmux`, so its
progress-only sidebar animation is unavailable while relayed; the session and
ordinary terminal output are unaffected.

## iPhone client

The iOS 17 app manages existing workers and `/workspace` projects. Repository
creation, Git operations, deployment, account usage, and worker administration
remain Mac-only. Build and run the **TerminalRelayIOS** scheme from
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

Enter the worker's Tailscale hostname or IP, SSH port, username, and the reported
`SHA256:...` fingerprint in iPhone setup. Every connection pins that fingerprint
and rejects a different host key. Worker connection fields are stored locally;
the generated private key never leaves Keychain.

A normal handoff is: start or attach on the Mac, disconnect or quit the Mac app,
attach to the same project and tool on iPhone, disconnect the iPhone, then choose
**Reconnect** on the Mac. If iOS loses its Keychain identity, authorize its newly
displayed public key. If the worker host key changes, verify the replacement
through a trusted administrative route before updating the pin. If discovery
fails because the helper is missing or outdated, re-run the helper installer and
retain its printed rollback command.
