# App Store metadata

## App record

- Platform: iOS universal app for iPhone and iPad
- Name: Terminal Relay: Self-Hosted
- Subtitle: Your workers. Direct over SSH.
- Primary language: English (U.S.)
- SKU: `terminal-relay-ios`
- Apple ID: `6804198744`
- App Store Connect status: Prepare for Submission
- Version: 1.0
- Current upload build: 10
- Copyright: 2026 AMURA VENTURES SL
- Primary category: Developer Tools
- Secondary category: Utilities
- Bundle ID: `com.mpieras.TerminalRelay.iOS`
- User access: Full Access
- License agreement: Apple's standard EULA
- Privacy policy:
  `https://miguelpieras.com/terminal-relay/privacy`
- Support:
  `https://miguelpieras.com/terminal-relay/support`
- Marketing:
  `https://miguelpieras.com/terminal-relay`

## Pricing and availability

- Price: Free
- Tax category: App Store software
- Distribution method: Public
- Availability: All current and future App Store countries or regions except
  France
- Pre-order: No
- Version release: Manual release after approval
- Phased release: Not applicable to the first version
- Education and business distribution: Available without a reduced price

## Content rights

Terminal Relay accesses repositories, terminal output and agent responses that
users make available on workers they control. It does not bundle or operate a
catalog of third-party content. The app is permitted to display the
user-authorized content and services it connects to.

## Promotional text

A native, open-source client for persistent Codex and Claude sessions on SSH
workers you own—without a hosted relay, app account, analytics, or tracking.

## Description

Terminal Relay is a native, open-source client for persistent Codex and Claude
coding sessions on SSH workers you own. It connects directly from your iPhone
or iPad to your worker—there is no Terminal Relay cloud, hosted relay, or app
account.

Use it to:

- Pair through the Mac app with a short-lived QR invitation that provisions a
  device-specific Ed25519 key.
- Pin every worker's SSH host key and communicate over a direct SSH connection.
- Browse repositories under `/workspace` and start or reconnect to persistent
  Codex and Claude sessions.
- Review native streamed responses, tool results, diffs, approvals, and file
  previews.
- Move between Mac, iPhone, and iPad without stopping the remote agent, with a
  live terminal available when needed.
- Monitor worker availability, resource usage, and agent account limits.

Terminal Relay does not provide hosted workers or agent accounts. You bring
your own SSH-accessible worker, Tailscale network, repositories, and Codex or
Claude account.

Terminal Relay is open source under the Apache License 2.0. Review the client
and worker code, follow development, or contribute on GitHub.

The app contains no advertising, analytics, or tracking.

## Keywords

selfhosted,ssh,terminal,developer,remote,agent,worker,coding,repository,private

## Age rating questionnaire

- Parental controls: No
- Age assurance: No
- Unrestricted web access: No
- User-generated content: No. The app does not distribute user content to
  other users.
- Social media: No
- Messaging and chat: No. Agent conversations are not person-to-person
  messaging.
- Advertising: None
- Violence, sexual content, profanity, drugs, gambling, contests, horror,
  medical content and loot boxes: None
- Made for Kids: No
- Override to a higher rating: No
- Expected Apple global rating: 4+. App Store Connect remains authoritative.

## App privacy

- Privacy policy URL:
  `https://miguelpieras.com/terminal-relay/privacy`
- Data collection answer: No, the developer and included third-party code do
  not collect data from this app.
- Tracking: No
- Privacy choices URL: Not applicable

Terminal Relay sends requests directly to the SSH workers and agent services
the user configures. Those user-directed connections are described in the
privacy policy and are not a developer-operated collection service.

## App Review contact

- Contact name: Miguel Pieras
- Contact email: `hey@miguelpieras.com`
- Contact phone: Set privately in App Store Connect; never commit it here.
- Sign-in required: No. The reviewer uses the private pairing credential in
  the review notes; dedicated agent accounts remain on the isolated worker.

## Review notes

REVIEW SETUP (about 30 seconds): Terminal Relay has no app account or hosted
demo. Pair the review device to the isolated worker with the code below to
exercise the complete submitted app.

Terminal Relay is a native client for user-owned SSH workers, not a hosted
relay service or repackaged web app. The app generates a device-specific
Ed25519 key. The normal onboarding flow scans a QR code created by the Mac app;
the code contains a short-lived SSH key restricted to authorizing that device
key and cannot open a shell. Camera frames are processed only on the device.

For App Review, we provide an isolated worker containing only synthetic
repositories and dedicated, limited agent accounts. It is not connected to our
private workers or Tailscale network. The private review pairing code is:

`[PASTE CURRENT CODE FROM MAINTAINER KEYCHAIN BEFORE SUBMISSION]`

1. Launch Terminal Relay on iPhone or iPad.
2. On the Projects screen, choose **Scan Mac Pairing Code**.
3. Choose **Paste Code** and paste the code above.
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

Terminal Relay is our original work, developed in public at
github.com/miguelpieras/terminal-relay (Apache License 2.0) by
AMURA VENTURES SL.

The product's distinct implementation is visible throughout the live review
path: direct SSH with no developer-operated relay, device-specific Keychain
identity, strict host-key pinning, persistent native Codex and Claude sessions,
streamed tool results and diffs, approvals, file previews, worker resource and
account-limit status, and a live terminal.

## Export compliance facts

- The app contains and uses encryption: Yes.
- It implements standard published encryption: Yes, through SSH, NIOSSH and
  Swift Crypto.
- It relies only on encryption built into Apple's operating system: No.
- It implements proprietary or non-standard cryptography: No.
- App Store Connect classification: Exempt from export documentation. The app
  implements industry-standard encryption outside Apple's operating system and
  is not distributed in France.
- Required documentation: None for the selected availability.

`ITSAppUsesNonExemptEncryption` is set to `NO` because Apple's classification
determined that the app's encryption use is exempt from documentation for the
selected availability. No
`ITSEncryptionExportComplianceCode` is included because no documentation is
required for the selected availability.

## EU Digital Services Act

The App Store Connect account is an organization account and identifies the
developer as a trader for this app. Apple uses the account's verified business
contact details on EU product pages.

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
screenshot fixtures. The fixtures use synthetic worker, repository, session,
account, SSH-key, and pairing values and never connect to a real worker. The
fixtures are excluded from Release builds.

## App Store Connect preparation status

- Product metadata and App Review contact saved.
- Content rights saved: the app has the necessary rights to display the
  user-authorized third-party content it accesses.
- Age rating saved: 4+ globally, with Apple's regional equivalents.
- App privacy published: Data Not Collected; no tracking.
- Pricing and availability saved: free, public, and available in all current
  countries or regions plus future App Store regions, except France.
- Four iPhone 6.9-inch and four iPad 13-inch screenshots uploaded in the order
  listed above.

## Remaining submission actions

- Provision and authenticate the isolated App Review worker, create its
  invitation, and paste the pairing code and expiration date into Review
  Notes.
- Upload the next signed universal build, attach it to version 1.0, and
  resubmit it for review.
