# Dedicated worker helper

`terminal-relay-session` is installed root-owned at `/usr/local/bin/terminal-relay-session` on Terminal Relay Worker 1. It takes a host-local `flock` for the selected tool before launching the existing root-owned Codex or Claude executable. This makes the one-Codex and one-Claude limit hold even if a second copy of Terminal Relay connects to the same server. For Codex sessions it also disables MCP servers declared in the system, worker, or current project's config; Terminal Relay launches Claude with strict MCP config and no MCP file.

The helper stores only transient lock files below `/run/user/<uid>/terminal-relay`. It does not manage credentials, repositories, terminal output, or background services.

`worker-config/` is the source of truth for worker-wide Codex and Claude guidance. From the repository root, run `./Scripts/sync-worker-guidance.sh [ssh-target ...]`; it defaults to `terminal-relay-worker-1`. The worker installer updates `~/AGENTS.md`, `~/CLAUDE.md`, `~/.codex/AGENTS.md`, and `~/.claude/CLAUDE.md`, preserving each differing file as a timestamped adjacent backup.
