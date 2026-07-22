# Terminal Relay

Terminal Relay is a native macOS workspace for Codex CLI and Claude Code sessions that run on remote servers. The app only starts the system SSH client locally; the coding agents, repositories, and account credentials stay on each server.

## What it does

- Keeps a project-first list of remote workspaces, each assigned to a reusable worker profile.
- Lists repositories from the authenticated GitHub account on the Mac and can create private repositories under `miguelpieras`.
- Uses the same remote path for every worker: `/workspace/<repository-name>`.
- Opens embedded, full interactive SSH terminals for Codex CLI and Claude Code.
- Allows one Codex session and one Claude session per worker at the same time, even when that worker hosts several projects.
- Uses the existing OpenSSH config, agent, known-hosts checks, and optional identity files on the Mac.
- Persists connection details and account labels, but never passwords, API keys, terminal output, or running-session state.

The first launch includes the dedicated **Terminal Relay Worker 1** profile. Its `terminal-relay-worker-1` SSH alias uses the existing private Tailscale route. The project list starts empty; Terminal Relay never creates or opens a generic Workspace project.

Each project expands into thin session rows in the sidebar. An animated spinner means the agent is working, a static colored dot means it is open and ready, and a gray outlined dot means it has exited. Exited sessions remain as history until closed, so one project can accumulate many Codex and Claude rows without implying that more than one of either tool is active on a worker.

That worker also has the small root-owned `terminal-relay-session` launcher from `Server/`. It uses one host-local lock per tool, so the server itself allows one Codex and one Claude process at a time even across separate app launches.

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

When a project is added, Terminal Relay uses the Mac's authenticated `gh` CLI to create or inspect the repository. It generates a dedicated deploy key on the selected worker, grants that key access only to the selected repository, and clones into `/workspace/<repository-name>`. The private key never leaves the worker, the GitHub credential never leaves the Mac, and no credential is stored in the project record or Git remote URL.
