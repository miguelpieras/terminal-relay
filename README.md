# Terminal Relay

Terminal Relay is a native macOS workspace for Codex CLI and Claude Code sessions that run on remote servers. The app only starts the system SSH client locally; the coding agents, repositories, and account credentials stay on each server.

## What it does

- Keeps a project-first list of remote workspaces, each assigned to a reusable worker profile.
- Stores an optional GitHub `owner/repository` identity for each project without storing GitHub credentials.
- Opens embedded, full interactive SSH terminals for Codex CLI and Claude Code.
- Allows one Codex session and one Claude session per worker at the same time, even when that worker hosts several projects.
- Uses the existing OpenSSH config, agent, known-hosts checks, and optional identity files on the Mac.
- Persists connection details and account labels, but never passwords, API keys, terminal output, or running-session state.

The first launch includes the dedicated **Terminal Relay Worker 1** profile. Its `terminal-relay-worker-1` SSH alias uses the existing private Tailscale route. Existing installs are migrated to a **Workspace** project at `/workspace`; new projects choose their own remote directory.

The sidebar always reserves one Codex dot and one Claude dot for every project. A colored dot means that project's terminal is open; a gray dot means it is closed. Working-versus-waiting activity signals are intentionally not inferred from terminal output.

That worker also has the small root-owned `terminal-relay-session` launcher from `Server/`. It uses one host-local lock per tool, so the server itself allows one Codex and one Claude process at a time even across separate app launches.

The concurrency limit applies to sessions started by Terminal Relay. It cannot detect an agent started independently in another SSH client.

## Requirements

- macOS 14 or later
- Xcode 26 or later
- `xcodegen` (`brew install xcodegen`)
- Working SSH access to each configured server
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

The approved GitHub authentication direction is a private Terminal Relay GitHub App with short-lived repository-scoped installation tokens. The current project UI records repository identity; token provisioning and repository cloning are a separate integration step.
