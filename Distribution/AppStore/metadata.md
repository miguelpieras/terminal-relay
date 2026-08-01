# App Store metadata

## Identity

- Name: Terminal Relay
- Subtitle: Remote AI coding sessions
- Primary category: Developer Tools
- Bundle ID: `com.mpieras.TerminalRelay.iOS`
- Privacy policy:
  `https://miguelpieras.com/terminal-relay/privacy`
- Support:
  `https://miguelpieras.com/terminal-relay/support`
- Marketing:
  `https://miguelpieras.com/terminal-relay`

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

For App Review, we provide an isolated worker containing only synthetic
repositories and dedicated, limited agent accounts. It is not connected to our
private workers or Tailscale network. The private review pairing code is:

`[PASTE CURRENT CODE FROM MAINTAINER KEYCHAIN BEFORE SUBMISSION]`

1. Launch Terminal Relay on iPhone or iPad.
2. On the Projects screen, choose **Scan Mac Pairing Code**.
3. Choose **Paste Pairing Code** and paste the code above.
4. Open `atlas` and start Codex or Claude. This uses the same interactive
   terminal, SSH/session flow, and interface as every user-owned worker.
5. Switch between `atlas`, `launchpad`, and `northstar`, reconnect to the active
   terminal, stop it, and open **Workers** to inspect account and resource
   status.

The invitation is valid through `[REVIEW EXPIRATION DATE]` for up to eight
review devices. Review device keys can run only Terminal Relay worker commands
and cannot request a general SSH shell or forwarding. The worker will remain
online throughout review. Real users pair with their own private workers using
the normal ten-minute, single-use Mac QR code.

Also answer App Store Connect's export-compliance questionnaire for the bundled
SSH and Swift Crypto implementation. Do not add
`ITSAppUsesNonExemptEncryption` until that classification is confirmed.

## Captured screenshots

- iPhone 6.9-inch:
  - `Distribution/Screenshots/AppStore/iPhone-6.9/01-projects.png`
  - `Distribution/Screenshots/AppStore/iPhone-6.9/02-active-sessions.png`
  - `Distribution/Screenshots/AppStore/iPhone-6.9/03-worker-dashboard.png`
  - `Distribution/Screenshots/AppStore/iPhone-6.9/04-private-connection.png`
- iPad 13-inch:
  - `Distribution/Screenshots/AppStore/iPad-13/01-adaptive-workspace.png`
  - `Distribution/Screenshots/AppStore/iPad-13/02-worker-dashboard.png`
  - `Distribution/Screenshots/AppStore/iPad-13/03-private-connection.png`
  - `Distribution/Screenshots/AppStore/iPad-13/04-agent-choice.png`
- Mac marketing site: `Distribution/Screenshots/mac.png`
- Mac pairing close-up: `Distribution/Screenshots/mac-pairing.png`

All images are direct captures of the native apps running with Debug-only
screenshot fixtures. The fixtures use example worker, repository, session,
account, SSH-key, and pairing values and never connect to a real worker.

## Remaining assets and decisions

- App Review contact information.
- Age rating, territories, price, and release method.
- Export-compliance answers and any requested documentation.
