# Terminal Relay

[![CI](https://github.com/miguelpieras/terminal-relay/actions/workflows/ci.yml/badge.svg)](https://github.com/miguelpieras/terminal-relay/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Terminal Relay is a native macOS and iPhone client for Codex CLI and Claude Code
sessions running on workers you control. Repositories, agent credentials, and
terminal processes remain on the worker; the apps connect over SSH.

## Features

- Project-first macOS workspace with embedded interactive terminals.
- Shared, persistent Codex and Claude sessions backed by worker-side `tmux`.
- Mac-to-iPhone handoff without stopping the remote agent.
- GitHub repository creation, deploy-key setup, and worker checkout from macOS.
- Multiple reusable workers and pinned SSH identities.
- Tailscale-friendly iPhone client with a device-specific Keychain identity.
- Optional Hetzner and Tailscale worker lifecycle automation.
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

## Architecture

The macOS app starts the system SSH client inside a pseudo-terminal. The iPhone
app uses SwiftNIO SSH and SwiftTerm. Both clients talk to the
`terminal-relay-session` helper installed on each worker.

The helper keeps one Codex and one Claude process per worker user, permits
multiple client attachments, and preserves restart intent across worker
reboots. Disconnecting a client leaves the remote agent running; **Stop Agent**
ends the exact shared session.

Terminal Relay does not operate a central backend:

```text
macOS app ─┐
           ├─ SSH over your network ─ worker ─ Codex / Claude
iPhone app ┘                         └ repositories in /workspace
```

## Requirements

- macOS 14 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Apple's Metal toolchain component
- Working SSH access to an Ubuntu 24.04 amd64 worker with at least 4 GB RAM
- GitHub CLI authenticated on the Mac for repository management
- Codex CLI and/or Claude Code accounts for the worker
- Tailscale on the iPhone and worker when using a private Tailscale route

## Development builds

Generate the Xcode project:

```bash
xcodegen generate
open TerminalRelay.xcodeproj
```

The macOS app intentionally does not enable App Sandbox because its embedded
terminal launches `/usr/bin/ssh`.

For an iPhone development build, select the `TerminalRelayIOS` scheme, choose
your Apple development team and bundle identifier if you are building a fork,
and run on a simulator or connected device.

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

## Configure the iPhone client

1. Install and connect Tailscale on the iPhone when the worker is private.
2. Open Terminal Relay and copy its generated Ed25519 public key.
3. Add that public key to the worker user's `~/.ssh/authorized_keys`.
4. Obtain the worker's ED25519 host-key fingerprint through an already trusted
   administrative connection.
5. Add the worker's name, hostname, SSH port, username, and fingerprint.

The private device key stays in Keychain. The app rejects a worker whose host
key does not match the pinned fingerprint. Worker connection details and read
state remain on the device.

## Distribution

Source availability and binary distribution are independent:

- Developers can clone the repository and sign a fork with their own Apple
  team and bundle identifiers.
- The maintained iPhone binary can be distributed through App Store Connect
  under the configured Terminal Relay application identifier.
- Every user still connects to their own private workers and accounts.

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
