# Dedicated worker helper

`terminal-relay-session` is installed root-owned at `/usr/local/bin/terminal-relay-session` on Terminal Relay Worker 1. It takes a host-local `flock` for the selected tool before launching the existing root-owned Codex or Claude executable. This makes the one-Codex and one-Claude limit hold even if a second copy of Terminal Relay connects to the same server.

The helper stores only transient lock files below `/run/user/<uid>/terminal-relay`. It does not manage credentials, repositories, terminal output, or background services.
