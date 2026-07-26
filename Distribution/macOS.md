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
repository guard and worker/macOS tests, archives with the Developer ID
Application identity, submits the ZIP to Apple's notary service, staples and
validates the app, creates the final ZIP with `ditto`, signs the archive and
appcast with Sparkle EdDSA, publishes the ZIP, appcast, and release notes to a
GitHub Release, then deploys only `appcast.xml` to GitHub Pages.

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

The certificate export, password, App Store Connect key, issuer identifier, and
Sparkle private key remain outside the repository. Workflow commands never echo
their values. Temporary certificate and key files live only in the hosted
runner's temporary directory.

## Operator verification

After the workflow completes:

1. Confirm the GitHub Release contains the notarized ZIP, Markdown release
   notes, and signed appcast.
2. Confirm GitHub Pages serves the expected appcast over HTTPS.
3. On an older signed build, choose **Check for Updates…**, accept the update,
   and confirm the standard Sparkle notification, install, relaunch, retained
   settings, and updated version.
4. Run `codesign --verify --deep --strict` and `spctl --assess --type execute`
   against the installed application.
5. Confirm no workflow log or release asset contains a private key, certificate
   password, App Store Connect credential, runner path, or signing environment
   value.

## Signing-key recovery constraint

The Sparkle public key is embedded in every shipped app. If its matching private
key is lost, a replacement key cannot sign an update trusted by those existing
installs. Rotate the key only through an update signed by the old key. If the old
key is unrecoverable, users must manually install a newly trusted application.
Keep the Sparkle key and Apple signing material in the maintainer's established
credential recovery system; never add a recovery copy to this repository.
