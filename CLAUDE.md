# CLAUDE.md

## What This Is

ParentalThingsAgent is the macOS menubar companion app for the Parental Things system. It polls the local iMessage database (`chat.db`) and Apple Notes, sends messages to the server for AI analysis, detects unsent/edited messages, and resolves contacts.

## Related Repos

- **Server:** [parental-things](https://github.com/greg-savage/parental-things) — Node.js server (AI analysis, notifications, web dashboard)
- **Parent iOS app:** [ParentalThings](https://github.com/greg-savage/ParentalThings) — parent dashboard, notifications, message review
- **Child iOS app:** [ParentalThingsChild](https://github.com/greg-savage/ParentalThingsChild) — installed on child's device, VPN-based monitoring

## Build

Open `ParentalThingsClient.xcodeproj` in Xcode. Requires macOS 13+, Xcode 15+.

## Architecture

- `Poller.swift` — main orchestrator: poll loop, drain batches, retry with backoff, heartbeat, Notes polling
- `IMessageDB.swift` — SQLite reader for `~/Library/Messages/chat.db`. Column is `attributedBody` (camelCase). DB opened with `SQLITE_OPEN_READWRITE` for WAL access.
- `NotesDB.swift` — SQLite reader for Apple Notes database
- `DatabaseWatcher.swift` — FSEvents-based watcher, triggers polls on DB changes
- `ContactResolver.swift` — resolves phone numbers/emails to names via Contacts framework
- `APIClient.swift` — REST client: ingest, heartbeat, events, contacts sync, watermark
- `ConfigurationView.swift` — server URL, API key, backfill days (stored in UserDefaults)
- `StatusView.swift` — menubar popover: connection status, stats, recent flagged messages
- `LogView.swift` — scrolling log viewer

## Key Details

- Bundle ID: `com.parentalthings.client`
- `attributedBody` is NSKeyedArchiver-encoded; fallback scans for `0x01 0x2B` marker
- Queries use `((text IS NOT NULL AND text != '') OR attributedBody IS NOT NULL)`
- Server API auth: Bearer token (child API key)
- Settings stored in UserDefaults (serverURL, apiKey, backfillDays)
