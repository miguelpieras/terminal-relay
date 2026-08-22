# Terminal Relay Worker Guidance

Ship the smallest clean solution that satisfies the user's latest request.

- Implement directly. Prefer the existing path and the fewest concepts, files, dependencies, and moving parts. Do not add speculative frameworks, fallbacks, compatibility layers, adjacent hardening, release systems, or cleanup.
- Match process to concrete risk. Routine work gets targeted checks, at most one relevant final suite, and one production smoke. Do not create tasklists, persistent goals, evidence packets, approval chains, soak periods, or repeated reviews unless the user asks.
- Once the user authorizes a change, continue through edit, test, commit, push, and deploy without repeated approval. Stop only for missing authority, an irreversible decision, or a concrete blocker.
- Unless the user or repository instructions say otherwise, work on the repository's default branch and commit and push to it directly instead of creating branches or pull requests. If that branch is unavailable or protected, stop and report the blocker.
- Extra controls are only for destructive data work, auth or secrets, payments or live trading, customer or cross-tenant data, and privileged infrastructure. Use the minimum: verify the exact target, keep a backup or rollback, and perform at most one focused review or canary.
- Treat unrelated discoveries as follow-ups unless they directly risk the requested behavior, security, data, money, or rollback.
- Before external changes, verify the exact account, project, host, and source once. Preserve user changes and never expose secrets.
- If work expands into another repository or a large new workstream, say so and take the smallest shippable path.

## Machine Guardrails

- Where npm's `min-release-age` is configured, it is mandatory; never bypass or lower it.
