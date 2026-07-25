# Contributing to Terminal Relay

Thanks for helping improve Terminal Relay.

## Before opening a change

- Discuss substantial behavior or architecture changes in a GitHub issue first.
- Never include credentials, private keys, real worker addresses, host-key
  fingerprints, provider resource IDs, personal filesystem paths, or terminal
  transcripts.
- Use `example-user`, `example-org`, `worker.example.com`, and documentation IP
  ranges in examples and tests.
- Keep machine-specific fleet settings in the ignored
  `Server/worker-baseline.local.env`.

## Development setup

Terminal Relay requires macOS 14 or later, Xcode 26 or later, XcodeGen, and
Apple's Metal toolchain component:

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
xcodegen generate
open TerminalRelay.xcodeproj
```

The macOS target uses the local SSH client and therefore intentionally runs
outside App Sandbox. iOS signing is needed only for physical-device builds;
forks should use their own development team and unique bundle identifiers.

## Tests

Run the focused public-repository and server checks:

```bash
./Scripts/check-public-repo.sh
./Server/Tests/terminal-relay-session-tests.sh
./Server/Tests/install-worker-session-helper-generation-tests.sh
./Server/Tests/worker-lifecycle-tests.sh
```

Before submitting an application change, regenerate the project and run the
relevant Xcode scheme tests. Maintainer delivery uses
`./Scripts/build-and-install.sh`.

## Pull requests

Keep pull requests focused, explain user-visible behavior, include tests for
changed behavior, and note any worker or release migration. Contributions are
accepted under the repository's Apache-2.0 license.
