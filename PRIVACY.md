# Privacy policy

Terminal Relay does not include advertising, analytics, tracking, or a
developer-operated data service.

## Data stored on your devices

The apps store worker connection settings, project references, display
preferences, opaque provider-account UUIDs and labels, last-known thread
catalog metadata, and read state locally. Thread catalog metadata is limited to
the configured worker, project name, provider and account identifiers, provider
thread identifier, relay instance identifier, title, activity time, archive/run
state, and supported actions. The universal iPhone and iPad
app creates an SSH private key in the device Keychain. Terminal Relay does not
upload that private key. Conversation titles can be provider-generated from
prompt content and may therefore contain sensitive text; the apps cache the
last received catalog locally for display.

Native-chat messages, reasoning, tool activity, diffs, approvals, questions,
usage, and bounded file previews are held only in app memory while their
conversation is open. The apps do not write that structured content to
`UserDefaults`, files, analytics, or a Terminal Relay service.

Older Mac builds briefly wrote reduced conversation state below
`Application Support/Terminal Relay/Conversation Cache`. Current builds do not
use that cache and remove that exact legacy directory at launch. They do not
remove provider-native Codex or Claude history or any sibling Application
Support data.

Files selected for a native chat message are read into app memory and sent
directly over the authenticated SSH connection only when you send that
message. The worker stores each upload temporarily in an owner-only directory
named with random relay, request, and attachment identifiers. The original
filename is sanitized display metadata and is not used as a worker path.

The iPhone and iPad app uses the camera only to scan a pairing code displayed
by the Mac app. Camera frames are processed on the device and are not stored or
transmitted. The short-lived pairing credential is sent directly to the worker
you selected and is removed from the worker after it authorizes the device key.

## Data sent to services you choose

Native-chat records, terminal sessions, repository operations, and account
requests are sent directly to workers and services configured by you,
including SSH servers, Tailscale, GitHub, Codex, or Claude. Native-chat records
can contain prompts, responses, reasoning summaries, tool input and output,
diffs, approval or question details, usage, and requested file previews. This
traffic stays inside the direct SSH connection to the worker you selected; the
Terminal Relay project and its maintainers do not receive it. Those configured
services process data under their own terms and privacy policies.

Thread catalog and mutation requests travel over the same direct SSH
connection. Before multi-account activation, the built-in worker MCP runs only
as stdio inside Codex or Claude on that worker and invokes the root-owned
session helper locally. Its tools
return project names and thread metadata, not prompts, transcript items,
terminal contents, credentials, or account data. It has no network listener and
cannot access another worker. Codex cataloging reads only IDs, project paths,
titles, activity times, archive flags, and source kinds from Codex's local
metadata index when a new preview-empty thread is not yet returned by the app
server; message and preview content are not selected.

After multi-account activation, the ambient worker MCP is disabled because an
account UUID supplied by a model or environment variable would not be an
authorization boundary. Accountless clients and helpers fail before a provider
process is launched.

Claude cataloging uses a pinned official Claude Agent SDK environment on the
worker. The SDK derives session ID, working directory, provider display title
or summary, and last-modified time from Claude's local provider history; a
summary or title can be derived from prompt text. Terminal Relay also asks
Claude Code's local agent registry for session ID and process ID and validates
the reported process before classifying activity. Provider entries whose
working directory is outside the selected repository or its Git worktrees are
not returned. Renaming is a provider-native mutation: the SDK appends a
custom-title entry to the provider transcript without rewriting it.

When native chat is attached, the worker uses Codex's app-server history API or
Claude's official SDK message-history API to build a bounded snapshot and page
older content on request. One worker-local broker retains only a bounded
in-memory snapshot, live replay window, unresolved interaction callbacks, and
identifier-only recovery metadata. It does not parse Claude JSONL, install a
transcript database, or send history to another worker or maintainer-operated
service.

Codex and Claude account profiles keep separate provider-native configuration,
credentials, and history roots on the worker. Claude Code keeps its own
conversation history in plaintext local provider storage under its retention
and cleanup policy. Terminal
Relay does not change that retention and does not install a transcript
`SessionStore`. Exact resume and reboot recovery work only while the provider
history remains on the same worker. Multi-device handoff sends the current
bounded structured view over direct SSH between your clients and that worker;
Terminal Relay does not copy history to another worker or a
maintainer-operated service.

Terminal Relay does not copy attached files into a repository, its transcript
state, or its replay window. The worker passes their temporary local paths to
Codex or Claude for the requested turn — for Claude, the sanitized display
names and paths become part of the prompt kept in that provider's own local
session history — then removes the exact request directory when
the turn completes, fails, or is interrupted. It also removes rejected or
cancelled uploads, clears the relay's attachment tree when its broker starts
or stops, and periodically removes unclaimed uploads older than ten minutes.

The chat renderer does not automatically fetch remote Markdown images. Opening
a validated `http` or `https` link hands it to the system browser. Repository
links request a bounded, read-only preview from the selected worker after it
verifies the canonical path remains inside that conversation's repository.

For Claude, archive state is a Terminal Relay-only visibility overlay. The
worker stores one mode-`0600` version marker, named by the provider session UUID,
inside a repository-scoped mode-`0700` relay state directory. The marker has no
title, prompt, transcript, account, or terminal content. Archiving does not
delete, retain, move, or modify the provider transcript and cannot prevent a
direct provider resume outside Terminal Relay.

Maintainer-signed macOS builds check a public GitHub Pages appcast once per day
and download accepted updates from GitHub Releases. Sparkle system profiling is
disabled, and Terminal Relay does not attach worker, account, project, or device
details to update requests. You can disable automatic checks, downloads, or
installation in the app and can always initiate a manual check. iPhone and iPad
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
