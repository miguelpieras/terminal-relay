# Automatic application updates and worker update notices

Context: Ship signed macOS updates through Sparkle and GitHub, leave iOS delivery to the App Store, and show sanitized worker-update failures when either client next connects. Closed-iPhone push notifications are not part of this launch path.

- [ ] Add Sparkle `2.9.2` as an exact macOS-only package in `project.yml`, record its license in `THIRD_PARTY_NOTICES.md`, and keep system profiling disabled.
- [ ] Configure the macOS bundle with the HTTPS appcast URL, Sparkle public EdDSA key, signed-feed verification, daily automatic checks, and user-controlled automatic installation; keep every private signing key and Apple credential outside the repository.
- [ ] Initialize Sparkle from `TerminalRelayApp`, add the standard **Check for Updates…** command, and use Sparkle's update alert and release-notes UI for available, critical, failed, and ready-to-install updates.
- [ ] Add focused macOS tests for updater configuration and command availability without making network requests during the test suite.
- [ ] Extend `terminal-relay-agent-update` to atomically publish a root-owned, sanitized last-run record containing the timestamp, success or failure, and installed Codex and Claude versions; expose it through a versioned read-only `terminal-relay-session update-status` response and cover success, partial failure, missing state, and malformed state in the worker tests.
- [ ] Query `update-status` during the existing macOS and iOS worker refresh paths, parse it with shared fixtures, and show a dismissible connection-time warning only when the most recent worker update failed.
- [ ] Add `Scripts/release-macos.sh` to require a clean `main`, a monotonically increasing macOS bundle version, the public-repository check, and passing tests before Developer ID signing, Apple notarization and stapling, Sparkle signing, and `ditto` packaging.
- [ ] Add a SHA-pinned GitHub Actions macOS release workflow that accepts only a version tag on the current `main`, imports credentials from GitHub secrets, runs the release script, publishes the notarized archive and release notes as GitHub Release assets, and deploys the generated signed `appcast.xml` to GitHub Pages over HTTPS.
- [ ] Configure the repository's GitHub Pages source and release environment, add only the required Apple and Sparkle values as encrypted GitHub secrets, and verify that logs and artifacts do not expose credential material.
- [ ] Update `README.md`, `Server/README.md`, and the distribution/privacy documentation with the macOS update behavior, App Store-managed iOS updates, worker warning semantics, release procedure, signing-key recovery constraint, and operator checks.
- [ ] Run `./Scripts/build-and-install.sh`, exercise one published old-to-new Sparkle update through notification, install, signature verification, relaunch, and retained settings, verify one worker success and failure notice on both clients, then run `./Scripts/check-public-repo.sh` and ship the verified changes directly to `main`.

## Follow-ups

- Add APNs-backed alerts for closed iPhones only if connection-time worker warnings prove insufficient.
- Add Sparkle beta channels, phased rollout, and delta archives after the first full-archive release path is stable.
