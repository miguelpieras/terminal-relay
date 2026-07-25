# Terminal Relay repository instructions

## Public repository hygiene

This repository is Apache-2.0 open source and must remain safe to publish.

- Never commit credentials, private keys, provisioning profiles, App Store
  Connect keys, OAuth material, real worker addresses, host-key fingerprints,
  provider resource IDs, fleet inventories, personal filesystem paths, account
  data, terminal contents, or private planning documents.
- Keep machine-specific worker settings only in the ignored
  `Server/worker-baseline.local.env`. Track reusable settings in
  `Server/worker-baseline.example.env` with `REPLACE_ME` placeholders.
- Use generic examples such as `example-user`, `example-org`,
  `worker.example.com`, and `terminal-relay-worker-N`.
- Before committing, run `./Scripts/check-public-repo.sh`. If private material
  ever reaches Git history, sanitize the reachable history before making the
  repository public and keep a protected local backup until the rewrite and
  force-push are verified.
- Preserve `LICENSE`, `PRIVACY.md`, `SECURITY.md`,
  `THIRD_PARTY_NOTICES.md`, and the privacy manifests when changing packaging.
  Update them when behavior, dependencies, or data handling changes.

## Apple distribution

- The maintained iOS app uses bundle identifier
  `com.mpieras.TerminalRelay.iOS` and Apple team `6EBZ756H9Q`. Forks must use
  their own team and unique bundle identifiers.
- Never commit certificates, provisioning profiles, `.p8` keys, issuer IDs, or
  signing passwords. Xcode account state and App Store Connect authentication
  stay outside the repository.
- Increment `CURRENT_PROJECT_VERSION` before every App Store Connect upload.
- Keep `TerminalRelayIOS/PrivacyInfo.xcprivacy` aligned with required-reason API
  use. Do not set `ITSAppUsesNonExemptEncryption` until the SSH/Swift Crypto
  export classification has been confirmed.
- `./Scripts/release-ios.sh export` creates the signed archive and export.
  `./Scripts/release-ios.sh upload` makes an external App Store Connect change
  and must only be run when the user explicitly requests an upload.
- Changing GitHub repository visibility is also an explicit external action;
  do not make the repository public unless the user asks to publish it.

## Delivery

After every user-requested change to this repository, run
`./Scripts/build-and-install.sh` before reporting completion. The command must
regenerate the Xcode project, pass all tests, build the Release app, install it
at `/Applications/Terminal Relay.app`, and relaunch it.

Do not report a requested change as complete when this command fails. Keep the
installed application path stable so its Dock item always opens the newest
successful build.

For authentication, worker-session, or terminal-launch failures, begin with
`docs/debugging.md`. It lists the safe app logs and worker checks to collect,
including data that must not be printed.
