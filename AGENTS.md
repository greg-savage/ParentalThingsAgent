# AGENTS.md

Guidelines for Claude Code sub-agents working in this repository.

## General Rules

- Read `CLAUDE.md` before starting any task — it has the architecture, related repos, and key details.
- Always create a branch for your work (never commit directly to `main`).
- Run `make build` before and after making changes to confirm you haven't broken the project.
- Make focused, conventional commits: `feat(scope):`, `fix(scope):`, `chore(scope):`, `docs(scope):`.
- `make deploy` / `make release` copy the built app to admin desktops and cut a GitHub release. Never run these without explicit instruction.

## SwiftUI / macOS Conventions

- SwiftUI menubar app; target is macOS 13+, Xcode 15+.
- No third-party dependencies — uses the C SQLite3 API directly, Contacts framework for name resolution, and FSEvents for DB watching. Keep it that way unless there's a very strong reason to pull in a package.
- Settings persist in `UserDefaults` (`serverURL`, `apiKey`, `backfillDays`). `KeychainHelper` is available if anything needs to be upgraded to secure storage.
- Bundle ID: `com.parentalthings.client`. `LSUIElement` is set — no dock icon, menubar only.

## iMessage DB (`~/Library/Messages/chat.db`)

This is where most of the footguns live. Read carefully before touching `IMessageDB.swift`:

- Column is `attributedBody` (camelCase), **not** `attributed_body`.
- On modern macOS, message text is often *only* in `attributedBody` — queries must include `((text IS NOT NULL AND text != '') OR attributedBody IS NOT NULL)` to avoid dropping messages.
- `attributedBody` is an `NSKeyedArchiver`-encoded `NSAttributedString`. Decode with `NSKeyedUnarchiver(forReadingFrom:)` and `requiresSecureCoding = false`. Fallback: scan the typedstream binary for the `0x01 0x2B` marker followed by length-prefixed UTF-8.
- The DB must be opened with `SQLITE_OPEN_READWRITE` — `READONLY` breaks WAL access and returns stale data.
- The app requires **Full Disk Access** (granted once by the user in System Settings) to read `chat.db`.

## Server API

- Auth is Bearer token (the child API key). Configured via `ConfigurationView`.
- The server API is documented implicitly by `APIClient.swift`. If you need to add a new endpoint, check the server repo (`parental-things`) `src/web/routes.ts` for the canonical contract.

## Cross-Repo Work

The server, parent iOS app, and child iOS app live in separate repositories (see `CLAUDE.md` § Related Repos). If a task needs coordinated changes across repos, document the contract (API shape, field names) in the commit message so the other side can match.
