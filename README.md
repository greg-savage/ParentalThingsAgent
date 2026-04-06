# ParentalThingsAgent — macOS Menubar App

SwiftUI macOS menubar app that polls the local iMessage database (`chat.db`) and Apple Notes, then sends messages to a [Parental Things](https://github.com/greg-savage/parental-things) server for AI analysis.

## Features

- **iMessage monitoring** — reads `chat.db` via SQLite, extracts text from `attributedBody` blobs, tracks watermark for incremental polling
- **Notes monitoring** — polls Apple Notes database for content changes
- **Image attachments** — sends image attachments (HEIC auto-converted to JPEG) to the server
- **Event detection** — detects unsent/edited messages and reports them to the server
- **Contact resolution** — resolves phone numbers to contact names via Contacts framework
- **Contact sync** — periodically syncs contacts to the server (every 6 hours)
- **Database watcher** — uses filesystem events to trigger polls on DB changes (not a fixed timer)
- **Heartbeat** — sends device status to the server every 60 seconds
- **Menubar UI** — shows unreviewed count badge, recent flagged messages, connection status
- **Configuration window** — server URL, API key, backfill days
- **Log viewer** — live log of polling activity

## Requirements

- macOS 13+
- Xcode 15+
- Full Disk Access (System Settings > Privacy > Full Disk Access) for reading `chat.db`
- Contacts access permission

## Setup

1. Open `ParentalThingsClient.xcodeproj` in Xcode
2. Set your **Team** under Signing & Capabilities
3. Build and run
4. Grant Full Disk Access when prompted (or manually in System Settings)
5. Enter the server URL and child API key in the Configuration window

## Architecture

```
ParentalThingsClient/
├── ParentalThingsClientApp.swift  # App entry point, menubar + windows
├── AppDelegate.swift              # App lifecycle, Poller setup
├── Poller.swift                   # Main orchestrator: poll loop, retry, heartbeat
├── IMessageDB.swift               # SQLite reader for chat.db
├── NotesDB.swift                  # SQLite reader for Apple Notes
├── DatabaseWatcher.swift          # FSEvents-based file change watcher
├── ContactResolver.swift          # Contacts framework integration
├── APIClient.swift                # REST client (ingest, heartbeat, events, contacts)
├── ConfigurationView.swift        # Server settings form
├── StatusView.swift               # Menubar popover with status + recent flags
└── LogView.swift                  # Live log viewer window
```

## License

Private — see the main [parental-things](https://github.com/greg-savage/parental-things) repo.
