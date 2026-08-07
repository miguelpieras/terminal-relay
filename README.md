# Terminal Relay

[![CI](https://github.com/miguelpieras/terminal-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/miguelpieras/terminal-relay/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Terminal Relay provides native macOS, iPhone, and iPad clients for Codex CLI
and Claude Code sessions running on workers you control. Repositories, agent
credentials, provider history, and agent processes remain on the worker; the
apps connect directly over SSH.

## Features

- Shared native streaming chat on macOS, iPhone, and iPad, including Markdown,
  code, tables, safe links, tool progress, diffs, approvals, and questions.
- Ephemeral Codex and Claude file attachments sent directly over SSH for one
  turn, then removed from the worker when that turn ends or is rejected.
- Persistent Codex and Claude conversations with multi-device handoff and
  fail-closed native-chat capability checks.
- Inactive and archived Codex and Claude conversations can be searched, resumed
  exactly, renamed, archived, and restored from macOS, iPhone, and iPad.
- Every managed agent session includes a worker-local MCP for safe project and
  thread operations on that worker.
- Handoff between Mac, iPhone, and iPad without stopping the remote agent.
- GitHub repository creation, deploy-key setup, and worker checkout from macOS.
- Multiple reusable workers and pinned SSH identities.
- Tailscale-friendly iPhone and iPad client with a device-specific Keychain
  identity.
- Private Mac-to-mobile pairing with a short-lived, single-use QR code.
- Optional Hetzner and Tailscale worker lifecycle automation.
- Signed, in-app macOS updates with daily checks and user-controlled installation.
- Signed, unattended worker-runtime updates shared by macOS, iPhone, and iPad.
- No advertising, analytics, tracking, or Terminal Relay cloud service.

Terminal Relay starts with no configured workers or GitHub owner. It reads the
currently authenticated GitHub CLI user on macOS and stores every connection
profile locally.

## Install on macOS

There is no prebuilt release yet. Install the current version from source:

```bash
git clone https://github.com/miguelpieras/terminal-relay.git
cd terminal-relay
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
./Scripts/build-and-install.sh
```

The install script regenerates the Xcode project, runs the test suite, builds
the Release app, installs it at `/Applications/Terminal Relay.app`, and opens
it. In the app, choose **Workers → Add Worker** to bootstrap a fresh Ubuntu
host or register an existing Terminal Relay worker.

## Use projects and threads

Freshly bootstrapped workers include the automatic worker-runtime updater. Run
one fleet reconciliation to add it to workers created by an older release:

```bash
./Scripts/manage-worker.sh reconcile all
```

Changes to the canonical worker-runtime payload publish the signed stable feed
automatically after they reach `main`. Bootstrap, reconciliation, App Review
provisioning, and helper-only repair verify that the feed version and signed
file digests match the checkout before changing a worker. If publication is
still running, wait for **Publish Worker Runtime** to finish and retry; the
production scripts never install a checkout ahead of the stable feed.

For an application-only worker, re-run its original
`./Scripts/bootstrap-worker.sh root@worker.example.com` command instead. After
this one-time enablement, signed runtime updates are checked automatically and
compatible clients can request an immediate fixed-channel check. Routine app
updates no longer require a manual worker migration.

Then use the apps:

1. Open a project in Terminal Relay. Live agents and inactive Codex and
   Claude conversations appear together below the project.
2. Choose **New Codex Thread** to create a paused conversation without opening
   it, or choose **Open Codex** / **Open Claude Code** to start working
   immediately.
3. Select an inactive Codex or Claude row to resume that exact conversation.
   On iPhone and iPad, open the project and tap a row under **Paused Threads**.
4. Control-click on Mac, or use swipe and context actions on iPhone and iPad,
   to rename or archive an inactive conversation. Expand **Archived Threads**
   to restore one.
5. Close the conversation to leave the current device without ending the
   worker agent. While a turn is running, the composer's Send control becomes
   Stop; with a hardware keyboard, pressing Escape twice also stops only that
   turn. Archiving a live conversation ends that exact relay instance first.

Claude list, metadata read, and rename use the official Claude Agent SDK;
resume uses Claude Code's exact provider session UUID. Terminal Relay archive
and unarchive are a worker-local visibility overlay: they do not delete, retain,
or change the Claude transcript and do not block a direct Claude Code resume.
Claude's configured retention still determines how long a conversation remains
resumable.

### Ask an agent to manage worker threads

Every Codex and Claude session opened by Terminal Relay already has the
worker-local `terminal_relay` MCP. There is nothing to install or configure in
the agent. For example, ask:

```text
Tell me about my open threads.

Create a Codex thread in example-repo, rename it "Investigate flaky tests",
and tell me its thread ID.

Resume thread 00000000-0000-4000-8000-000000000000 in example-repo so I can
attach to it from Terminal Relay.

Archive the inactive Claude thread 00000000-0000-4000-8000-000000000000 in
example-repo.
```

For the first request, the MCP instructions tell the agent to discover the
worker's projects and list each project's unarchived conversations, including
live terminals and inactive Codex and Claude conversations.

The MCP can list projects and conversations; start a Codex thread; resume or
rename Codex and Claude conversations; and archive or restore inactive
conversations on the current worker. It cannot read transcripts, type into
terminals, run arbitrary shell commands, delete projects or conversations, or
access another worker.

Maintainer-signed macOS releases use Sparkle. The app checks the public signed
feed once per day without sending system-profile data. Use **Terminal Relay →
Check for Updates…** at any time; automatic checks, downloads, and installation
remain configurable in **Settings → Agent Defaults**. iPhone and iPad updates
continue to be installed through the App Store. These mechanisms update client
binaries only. A separate Ed25519-signed stable feed updates the bounded
root-owned runtime on each worker; it never copies repositories, credentials,
provider history, relay metadata, restart intents, or terminal contents.

## Architecture

For native chat, macOS starts the system SSH client without a PTY and iPhone
and iPad use a bidirectional SwiftNIO SSH exec channel. Structured NDJSON moves
only between the app and `terminal-relay-session` on the selected worker. One
worker-local `terminal-relay-chat` broker owns each live provider conversation,
listens only on a mode-`0600` Unix socket, and keeps a bounded in-memory replay
window. It has no TCP listener or transcript database.

The same clients can still display already-running legacy PTY/SwiftTerm
sessions, but native-chat creation and resumption never fall back to a raw
terminal. If the worker does not advertise native chat, the request fails
closed until the worker is updated. The helper supports concurrent Codex and
Claude agents, permits multiple client attachments, and preserves exact
restart intent across worker reboots. Closing a client leaves the remote agent
running.

Codex's worker-local app server and the official Claude Agent SDK provide
paginated catalogs of persisted conversations. The apps keep each provider
session UUID separate from the relay terminal UUID, so selecting an inactive
row resumes that exact provider conversation and a reboot restores the same
provider UUID. Claude activity is classified by combining validated
`claude agents --json` process records with relay state; externally active or
unknown conversations remain visible but cannot be resumed or mutated.

The provider's worker-local history remains authoritative. Native clients keep
only their currently rendered conversation in memory, and the broker keeps
only a bounded materialized snapshot and replay window in memory. On a replay
gap or broker restart it rebuilds from Codex or Claude history on that same
worker. Terminal Relay does not add a transcript store or cross-worker
migration. Moving to a different worker or replacing its disk requires a
separate provider-data migration.

Managed Codex and Claude terminals receive
`/usr/local/bin/terminal-relay-mcp`, a root-owned stdio MCP server with only
seven bounded tools: list projects and conversations, start a Codex thread,
resume Codex or Claude conversations, and rename, archive, or unarchive an
inactive conversation. It delegates to the same typed worker helper and has no
listener, shell, transcript reader, terminal input, deletion, or cross-worker
access.

Terminal Relay does not operate a central backend:

```text
macOS app ───────┐
                 ├─ direct SSH ─ worker ─ chat broker ─ Codex / Claude
iPhone/iPad app ┘              ├ repositories in /workspace
                               ├ local thread MCP (stdio only)
                               └ existing legacy PTY sessions
```

## Requirements

- macOS 14 or later
- Xcode 26 or later
- [XcodeGen 2.46.0 or later](https://github.com/yonaskolb/XcodeGen)
- Apple's Metal toolchain component
- Working SSH access to an Ubuntu 24.04 amd64 worker with at least 4 GB RAM
- GitHub CLI authenticated on the Mac for repository management
- Codex CLI and/or Claude Code accounts for the worker
- Tailscale on the iPhone or iPad and worker when using a private Tailscale
  route

## Development builds

Generate the Xcode project:

```bash
xcodegen generate
open TerminalRelay.xcodeproj
```

The macOS app intentionally does not enable App Sandbox because its embedded
terminal launches `/usr/bin/ssh`.

For an iPhone or iPad development build, select the `TerminalRelayIOS` scheme,
choose your Apple development team and bundle identifier if you are building a
fork, and run on a simulator or connected device.

## Configure a worker

The macOS app's **Workers → Add Worker** screen provides a copyable bootstrap
command for a fresh host. It can also store connection details for a host that
already has the Terminal Relay runtime installed; manual registration does not
create or configure that host. Successful bootstrap or managed provisioning
registers the worker in the app automatically.

### Managed Hetzner and Tailscale lifecycle

Copy the public template into the ignored machine-specific configuration:

```bash
cp Server/worker-baseline.example.env Server/worker-baseline.local.env
```

Replace every `REPLACE_ME` value with identifiers and public-key material for
your own infrastructure. Never put provider credentials, OAuth secrets, private
keys, live addresses, or fleet inventories in tracked files.

Configure the local provider clients once, then provision a numbered worker:

```bash
./Scripts/manage-worker.sh configure
./Scripts/manage-worker.sh provision 1
```

The Tailscale OAuth credential is stored in macOS Keychain. The Hetzner token
remains in a local `hcloud` context. Provisioning creates the worker, enrolls
Tailscale, applies the declared host baseline, installs the application runtime,
completes agent authentication, and registers the worker in the macOS app.

Reconcile, verify, or retire your configured workers with:

```bash
./Scripts/manage-worker.sh reconcile all
./Scripts/manage-worker.sh verify all
./Scripts/manage-worker.sh retire 1
```

Retirement refuses active sessions, dirty worktrees, missing upstreams, and
unpushed commits before asking for an exact destructive confirmation.

### Application-only bootstrap

If you manage networking and host security separately, bootstrap an existing
Ubuntu host:

```bash
./Scripts/bootstrap-worker.sh [--identity PATH] [--port N] root@worker.example.com
```

The command verifies the exact target, keeps normal OpenSSH host-key checking,
installs the unprivileged `terminal-relay` runtime, authenticates the selected
agent CLIs interactively, and registers the worker only after readiness checks
pass. Re-run the same command to update or recover the managed runtime.

See [Server/README.md](Server/README.md) for the worker contract, installed
paths, session protocol, recovery behavior, and helper-only update flow.

## Configure the iPhone or iPad client

1. Install and connect Tailscale on the iPhone or iPad when the worker is
   private.
2. On the Mac, open **Workers**, use the worker's action menu, and choose
   **Pair iPhone or iPad**.
3. On the iPhone or iPad, open Terminal Relay, tap **Scan Mac Pairing Code**,
   and scan the code.

The Mac creates a restricted SSH invitation that expires after 10 minutes and
can authorize one device key but cannot open a shell. The mobile app verifies
the worker's ED25519 host key before enrollment, replaces the invitation with
its permanent public key, and saves the connection locally. No pairing service
or Terminal Relay account is involved. The private device key stays in
Keychain. Manual worker entry remains available as a fallback.

## Distribution

Source availability and binary distribution are independent:

- Developers can clone the repository and sign a fork with their own Apple
  team and bundle identifiers.
- The maintained universal iPhone and iPad binary can be distributed through
  App Store Connect under the configured Terminal Relay application identifier.
- Maintainer-signed macOS binaries are Developer ID signed, notarized, and
  delivered from GitHub Releases through a signed Sparkle feed on GitHub Pages.
- Every user still connects to their own private workers and accounts.

A macOS release is cut by pushing a version tag that matches
`MARKETING_VERSION` on the current `main`. The `macos-release`
environment runs `Scripts/release-macos.sh`, publishes the notarized ZIP and
release notes, signed worker runtime, and signed appcast. The workflow deploys
the worker feed before publishing the corresponding client release. See
[Distribution/macOS.md](Distribution/macOS.md) for the credential names,
verification checks, and recovery constraint.

Create a signed App Store archive and exported package:

```bash
./Scripts/release-ios.sh export
```

After the App Store Connect record, metadata, review access, privacy answers,
and export-compliance answers are complete, upload with:

```bash
./Scripts/release-ios.sh upload
```

The upload command requires the maintainer's Apple account in Xcode or an App
Store Connect authentication key supplied directly to Xcode. Signing keys and
authentication keys must never enter this repository.

See [Distribution/AppStore/metadata.md](Distribution/AppStore/metadata.md) for
the prepared listing copy and the remaining submission-only fields.

Maintainers provide App Review with an isolated, synthetic worker reached
through the production iPhone and iPad pairing flow. Its lifecycle and
reviewer instructions are documented in
[docs/app-review-worker.md](docs/app-review-worker.md); reusable review access
never applies to normal user workers.

## Security and privacy

Read [SECURITY.md](SECURITY.md) before reporting a vulnerability and
[PRIVACY.md](PRIVACY.md) for the data-handling policy. Debugging guidance in
[docs/debugging.md](docs/debugging.md) identifies safe checks and information
that must not be copied into issues.

Run the public-repository guard before every release:

```bash
./Scripts/check-public-repo.sh
```

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup,
tests, and public-repository hygiene.

Terminal Relay is licensed under the [Apache License 2.0](LICENSE). Bundled
dependency licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Created and maintained by [Miguel Pieras (@mpieras)](https://x.com/mpieras).
