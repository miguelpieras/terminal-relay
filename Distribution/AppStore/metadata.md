# App Store metadata

## App record

- Platform: iOS universal app for iPhone and iPad
- Name: Terminal Relay: AI Coding
- Subtitle: Private AI coding sessions
- Primary language: English (U.S.)
- SKU: `terminal-relay-ios`
- Apple ID: `6804198744`
- App Store Connect status: Prepare for Submission
- Version: 1.0
- Current upload build: 7
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

Continue your remote Codex and Claude coding sessions from your iPhone or iPad.

## Description

Terminal Relay connects your iPhone or iPad to coding-agent sessions running
on workers you control.

Use it to:

- Browse projects stored under `/workspace` on your workers.
- Start or reconnect to Codex and Claude terminal sessions.
- Move between Mac, iPhone, and iPad without stopping the remote agent.
- Monitor worker availability and resource usage.
- Explore a complete built-in demo before pairing a worker.
- Pair securely with the Mac app by scanning a short-lived QR code.
- Keep a dedicated SSH identity in the device Keychain.
- Pin every worker's SSH host key.

Terminal Relay does not provide hosted workers or agent accounts. You bring
your own SSH-accessible worker, Tailscale network, repositories, and Codex or
Claude account.

Terminal Relay is open source under the Apache License 2.0. Review the client
and worker code, follow development, or contribute on GitHub.

The app contains no advertising, analytics, or tracking.

## Keywords

terminal,ssh,coding,developer,remote,agent,worker,devtools,repository,private

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
- Sign-in required: No. The built-in offline demo provides the complete review
  path without an account or pairing credential.

## Review notes

Terminal Relay is a client for user-owned SSH workers. The app generates a
device-specific Ed25519 key. The normal onboarding flow scans a QR code created
by the Mac app; the code contains a short-lived SSH key restricted to
authorizing that device key and cannot open a shell. Camera frames are
processed only on the device.

The review path is built into the submitted app and makes no network requests:

1. Launch Terminal Relay on iPhone or iPad.
2. On the empty Projects screen, choose **Explore Demo**.
3. Open `atlas`, then open **Build adaptive iPad workspace** to inspect the
   complete native agent conversation, tools, diff, approval, and error states.
4. Return to Projects and switch among `atlas`, `launchpad`, and `northstar`.
5. Open **Workers** to inspect the synthetic worker, agent accounts, capacity,
   and resource status.

The demo uses only bundled synthetic data (`worker.example.com`, example
repositories, and example accounts). Nothing is persisted as a real worker.
Real users pair with their own private workers using the normal ten-minute,
single-use Mac QR code.

## Export compliance facts

- The app contains and uses encryption: Yes.
- It implements standard published encryption: Yes, through SSH, NIOSSH and
  Swift Crypto.
- It relies only on encryption built into Apple's operating system: No.
- It implements proprietary or non-standard cryptography: No.
- App Store Connect classification: Non-exempt encryption. The app implements
  industry-standard encryption outside Apple's operating system and is not
  distributed in France.
- Required documentation: None for the selected availability.

`ITSAppUsesNonExemptEncryption` is set to `YES`. No
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
screenshot fixtures. The fixtures use example worker, repository, session,
account, SSH-key, and pairing values and never connect to a real worker.

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

- Upload signed universal build 7, attach it to version 1.0, and submit it for
  review.
