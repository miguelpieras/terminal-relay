# Privacy policy

Terminal Relay does not include advertising, analytics, tracking, or a
developer-operated data service.

## Data stored on your devices

The apps store worker connection settings, project references, display
preferences, and account labels locally. The iPhone app creates an SSH private
key in the device Keychain. Terminal Relay does not upload that private key.

## Data sent to services you choose

Terminal sessions, repository operations, and account requests are sent
directly to workers and services configured by you, including SSH servers,
Tailscale, GitHub, Codex, or Claude. Those services process data under their own
terms and privacy policies. The Terminal Relay project and its maintainers do
not receive this traffic.

Maintainer-signed macOS builds check a public GitHub Pages appcast once per day
and download accepted updates from GitHub Releases. Sparkle system profiling is
disabled, and Terminal Relay does not attach worker, account, project, or device
details to update requests. You can disable automatic checks, downloads, or
installation in the app and can always initiate a manual check. iPhone
application updates are managed by the App Store.

When a client connects to one of your workers, it may read a root-owned
last-update record over the existing SSH connection. That response is limited
to a timestamp, success or failure, and sanitized installed Codex and Claude
version strings. It is not sent to the maintainer.

## Diagnostics

The apps do not transmit diagnostics to the maintainer. If you choose to file a
GitHub issue, remove account information, credentials, private addresses,
terminal contents, and other sensitive data first.

## Contact

For privacy questions, open a GitHub issue that contains no sensitive data. For
security-sensitive reports, follow [SECURITY.md](SECURITY.md).

This policy applies to the open-source Terminal Relay apps distributed from
this repository. A distributor of a modified build is responsible for
documenting any different data practices.
