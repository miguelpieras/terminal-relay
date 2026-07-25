# Security policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's
**Report a vulnerability** action in the repository Security tab so the report,
discussion, and any proof of concept remain private.

Include the affected version, impact, reproduction steps, and the smallest safe
proof of concept. Remove credentials, private addresses, account details,
terminal contents, and worker data before attaching logs.

The maintainer will acknowledge a complete report as soon as practical,
coordinate a fix and disclosure privately, and credit reporters who want public
recognition.

## Supported versions

Security fixes are made on `main` and shipped in the newest available release.
Older builds are not supported after an update is published.

## Security model

Terminal Relay is a client for infrastructure controlled by its user:

- SSH private keys remain in the macOS filesystem or iOS Keychain.
- Agent credentials and repositories remain on user-configured workers.
- Worker host keys are verified or explicitly pinned.
- The project does not operate a shared Terminal Relay backend.

Users are responsible for their worker operating systems, Tailscale policy,
SSH authorization, agent accounts, repository permissions, backups, and
credential rotation.
