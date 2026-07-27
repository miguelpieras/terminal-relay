# App Store metadata

## Identity

- Name: Terminal Relay
- Subtitle: Remote AI coding sessions
- Primary category: Developer Tools
- Bundle ID: `com.mpieras.TerminalRelay.iOS`
- Privacy policy:
  `https://github.com/miguelpieras/terminal-relay/blob/main/PRIVACY.md`
- Support:
  `https://github.com/miguelpieras/terminal-relay/issues`
- Marketing:
  `https://github.com/miguelpieras/terminal-relay`

## Promotional text

Continue your remote Codex and Claude coding sessions from your iPhone or iPad.

## Description

Terminal Relay connects your iPhone or iPad to coding-agent sessions running
on workers you control.

Use it to:

- Browse projects stored under `/workspace` on your workers.
- Start or reconnect to Codex and Claude terminal sessions.
- Move between Mac, iPhone, and iPad without stopping the remote agent.
- Monitor worker availability and resource usage.
- Pair securely with the Mac app by scanning a short-lived QR code.
- Keep a dedicated SSH identity in the device Keychain.
- Pin every worker's SSH host key.

Terminal Relay does not provide hosted workers or agent accounts. You bring
your own SSH-accessible worker, Tailscale network, repositories, and Codex or
Claude account.

The app contains no advertising, analytics, or tracking.

## Keywords

terminal,ssh,coding,developer,codex,claude,remote,tailscale

## Review notes

Terminal Relay is a client for user-owned SSH workers. The app generates a
device-specific Ed25519 key. The normal onboarding flow scans a QR code created
by the Mac app; the code contains a short-lived SSH key restricted to
authorizing that device key and cannot open a shell. Camera frames are
processed only on the device.

Before submitting, replace this paragraph with exact instructions for an
Apple-accessible review worker or an in-app demonstration path. Do not expose a
production worker, reusable credential, or private Tailscale network.

Also answer App Store Connect's export-compliance questionnaire for the bundled
SSH and Swift Crypto implementation. Do not add
`ITSAppUsesNonExemptEncryption` until that classification is confirmed.

## Required assets outside the repository

- At least one current iPhone screenshot.
- At least one current iPad screenshot.
- App Review contact information.
- Age rating, territories, price, and release method.
- Export-compliance answers and any requested documentation.
