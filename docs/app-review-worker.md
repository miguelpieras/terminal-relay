# App Review worker

The maintained App Store build is reviewed against one disposable worker that
contains only synthetic repositories and dedicated agent accounts. Reviewers
pair through the production iPhone and iPad onboarding flow, so the tested
sidebar, terminal, SSH transport, session controls, and recovery behavior are
the same code paths used with customer-owned workers.

The review worker is intentionally separate from the private fleet:

- It has its own provider firewall and public key-only SSH endpoint.
- It is not enrolled in Tailscale and has no route to private workers.
- Review device keys are capped and forced through
  `terminal-relay-review-gateway`; they cannot request a general SSH shell or
  forwarding.
- Its `atlas`, `launchpad`, and `northstar` repositories contain fictional
  local files, no remotes, deploy keys, credentials, or user data.
- Its Codex and Claude logins must be dedicated, spend-limited review accounts.
- CPU, memory, task, and disk use are bounded by the review VM and its systemd
  user-slice policy.

## Maintainer lifecycle

The lifecycle reads provider and operator-key settings from the ignored
`Server/worker-baseline.local.env`. It verifies the configured project before
making an external change.

```bash
./Scripts/manage-review-worker.sh provision
./Scripts/manage-review-worker.sh authenticate
./Scripts/manage-review-worker.sh invite --days 30 --max-devices 8
./Scripts/manage-review-worker.sh verify
```

`authenticate` is interactive and must use accounts created only for App
Review. `invite` stores the reusable pairing code in macOS Keychain and copies
it to the clipboard without printing it. Paste that value only into App Store
Connect Review Notes.

Useful review-window operations:

```bash
./Scripts/manage-review-worker.sh copy-code
./Scripts/manage-review-worker.sh reset
./Scripts/manage-review-worker.sh revoke
./Scripts/manage-review-worker.sh retire
```

`reset` stops active synthetic sessions, restores all fixture repositories, and
removes enrolled reviewer device keys while preserving the current invitation.
`revoke` removes the invitation and every enrolled review key. `retire`
permanently deletes the disposable VM and its dedicated firewall after the
review is complete.

## Reviewer flow

1. Install Terminal Relay on an iPhone or iPad.
2. On the Projects screen, choose **Scan Mac Pairing Code**.
3. Choose **Paste Pairing Code** and paste the private code from Review Notes.
4. Open `atlas`, start either agent, type in the real terminal, switch projects,
   reconnect, and stop the session.
5. Open **Workers** to inspect connection, account, and resource status.

The invitation is reusable only so Apple can enroll multiple review devices.
It expires at the declared time, has a fixed device cap, pins the worker’s
ED25519 host key, and can be rotated or revoked locally at any time.
