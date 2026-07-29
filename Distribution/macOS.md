# macOS release and update distribution

Terminal Relay uses Sparkle `2.9.2` for maintainer-signed macOS updates. The app
checks `https://miguelpieras.github.io/terminal-relay/appcast.xml` daily, accepts
only a correctly signed feed and archive, and never enables Sparkle system
profiling. Users retain control of automatic checks, downloads, and
installation. iOS remains App Store managed and does not use Sparkle.

## Release contract

A release tag must:

- match `v<MARKETING_VERSION>`;
- point to the current `origin/main` commit;
- be built from a clean checkout; and
- use a numeric `CFBundleVersion` newer than the newest published appcast item.

The `Release macOS` workflow runs only after those checks. It runs the public
repository guard and worker/macOS tests, builds the deterministic worker
runtime from `Server/worker-runtime-files.txt`, signs its manifest with a
dedicated Ed25519 key, archives with the Developer ID Application identity,
notarizes the app, and signs the app archive and appcast with Sparkle EdDSA.
It creates the GitHub Release as a draft, atomically deploys the runtime feed,
runtime archive, app archive, and appcast to GitHub Pages, then publishes the
draft release. The corresponding client is therefore not exposed before its
worker runtime.

To cut a release, update `MARKETING_VERSION`, commit and push the tested change
to `main`, then create and push the matching tag:

```bash
git tag v1.1
git push origin v1.1
```

The release workflow uses the protected `macos-release` GitHub environment and
these encrypted environment secrets:

- `MACOS_DEVELOPER_ID_P12_BASE64`
- `MACOS_DEVELOPER_ID_P12_PASSWORD`
- `APPLE_API_KEY_BASE64`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`
- `WORKER_RUNTIME_SIGNING_KEY`

The certificate export, password, App Store Connect key, issuer identifier, and
Sparkle and worker-runtime private keys remain outside the repository. Workflow
commands never echo their values. Temporary certificate and key files live
only in the hosted runner's temporary directory. The runtime secret is an
unencrypted PEM Ed25519 private key; the workflow derives its public key and
requires an exact match with `Server/terminal-relay-runtime-update.pub` before
building.

## Operator verification

After the workflow completes:

1. Confirm the GitHub Release contains the notarized ZIP, Markdown release
   notes, signed appcast, worker manifest, manifest signature, and runtime
   archive.
2. Confirm GitHub Pages serves the expected appcast and signed runtime manifest
   over HTTPS, and that the manifest archive URL resolves.
3. On a managed worker, run `terminal-relay-session runtime-update-request`,
   poll `runtime-update-status`, and confirm `runtime-info` reaches the released
   version without stopping an attached Codex or Claude terminal.
4. On an older signed build, choose **Check for Updates…**, accept the update,
   and confirm the standard Sparkle notification, install, relaunch, retained
   settings, and updated version.
5. Run `codesign --verify --deep --strict` and `spctl --assess --type execute`
   against the installed application.
6. Confirm no workflow log or release asset contains a private key, certificate
   password, App Store Connect credential, runner path, or signing environment
   value.

## Signing-key recovery constraint

The Sparkle public key is embedded in every shipped app. If its matching private
key is lost, a replacement key cannot sign an update trusted by those existing
installs. Rotate the key only through an update signed by the old key. If the old
key is unrecoverable, users must manually install a newly trusted application.
Keep the Sparkle key and Apple signing material in the maintainer's established
credential recovery system; never add a recovery copy to this repository.

The worker-runtime key has a separate trust chain. To rotate it, publish one
runtime signed by the old key that installs the new public key, verify the fleet
has converged, then use the new private key for later releases. The stable
manifest keeps client protocols 1–2 and legacy helper commands during this
compatibility window. If the runtime private key is lost before a signed
rotation, unattended updates cannot establish a new key: update the tracked
public key and perform one privileged fleet reconciliation. Never bypass
signature or monotonic-version checks, and never add a private-key recovery copy
to the repository.
