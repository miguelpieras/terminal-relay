# Dedicated worker helper

`agent-console-session` is installed root-owned at `/usr/local/bin/agent-console-session` on Agent Console Worker 1. It takes a host-local `flock` for the selected tool before launching the existing root-owned Codex or Claude executable. This makes the one-Codex and one-Claude limit hold even if a second copy of Agent Console connects to the same server.

The helper stores only transient lock files below `/run/user/<uid>/agent-console`. It does not manage credentials, repositories, terminal output, or background services.
