import AppKit
import Foundation
import IOKit
import os

private let logger = Logger(subsystem: "com.parentalthings.client", category: "poller")

private let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let message: String

    enum LogLevel: String {
        case info, warning, error
    }

    var formatted: String {
        let ts = date.formatted(.dateTime.hour().minute().second())
        return "[\(ts)] \(level.rawValue.uppercased()): \(message)"
    }
}

@Observable
final class Poller {

    // Published state for UI
    private(set) var isRunning = false
    private(set) var lastPollTime: Date?
    private(set) var lastError: String?
    private(set) var totalProcessed = 0
    private(set) var totalFlagged = 0
    private(set) var isPolling = false
    private(set) var dbConnected = false
    private(set) var contactsStatus = "Not loaded"
    private(set) var logEntries: [LogEntry] = []
    private(set) var unreviewedCount = 0
    private(set) var recentFlagged: [RecentFlaggedMessage] = []

    private(set) var notesProcessed: Int = 0
    private(set) var notesFlagged: Int = 0

    private(set) var errorCount = 0
    private var lastIngestTime: Date?
    private let appLaunchTime = Date()

    private static let deviceId: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let data = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            return UUID().uuidString
        }
        return data
    }()

    private static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    private static let appVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }()

    private var pollTask: Task<Void, Never>?
    private var watcher: DatabaseWatcher?
    private let contactResolver = ContactResolver()
    private var lastContactSync: Date?
    private var lastEventCheckTimestamp: Int64 = 0
    private var currentClient: APIClient?

    private func log(_ level: LogEntry.LogLevel, _ message: String) {
        let entry = LogEntry(date: Date(), level: level, message: message)
        Task { @MainActor in
            logEntries.append(entry)
            if logEntries.count > 200 {
                logEntries.removeFirst(logEntries.count - 200)
            }
        }
        switch level {
        case .info:    logger.info("\(message)")
        case .warning: logger.warning("\(message)")
        case .error:   logger.error("\(message)")
        }
    }

    /// Read settings from UserDefaults and start polling if configured.
    func startIfConfigured() {
        let serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        let apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        guard !serverURL.isEmpty, !apiKey.isEmpty else {
            stop()
            return
        }
        let days = UserDefaults.standard.integer(forKey: "backfillDays")
        start(
            serverURL: serverURL,
            apiKey: apiKey,
            backfillDays: days > 0 ? days : 7
        )
    }

    func start(serverURL: String, apiKey: String, backfillDays: Int) {
        stop()

        let client = APIClient(serverURL: serverURL, apiKey: apiKey)
        currentClient = client
        let db = IMessageDB()

        isRunning = true
        dbConnected = db.isConnected
        lastError = db.isConnected ? nil : db.lastError

        let dbWatcher = DatabaseWatcher(path: db.dbPath)
        watcher = dbWatcher

        log(.info, "Poller started — watching \(db.dbPath), server: \(serverURL)")

        dbWatcher.start()

        pollTask = Task { [weak self] in
            // Request contacts access before first poll so the system dialog
            // appears reliably (semaphore inside a Task can deadlock).
            await self?.contactResolver.requestAccessIfNeeded()

            // Update contacts status immediately (don't wait for first poll)
            if let resolver = self?.contactResolver {
                let status = resolver.authorized
                    ? "\(resolver.contactCount) contacts"
                    : resolver.lastError ?? "Not authorized"
                await MainActor.run { self?.contactsStatus = status }
            }

            // Notes monitoring
            if let notesPath = NotesDB.defaultPath {
                let notesDb = NotesDB(path: notesPath)
                let notesWatcher = DatabaseWatcher(path: notesPath)
                notesWatcher.start()
                self?.log(.info, "Notes monitoring started: \(notesPath)")

                // Notes watcher task
                Task { [weak self] in
                    for await _ in notesWatcher.events {
                        guard let self, self.isRunning else { break }
                        await self.pollNotes(client: client, notesDb: notesDb)
                    }
                }

                // Initial notes poll
                Task { [weak self] in
                    await self?.pollNotes(client: client, notesDb: notesDb)
                }
            } else {
                self?.log(.warning, "Notes database not found — Notes monitoring disabled")
            }

            // Run immediately on start
            await self?.poll(client: client, db: db, backfillDays: backfillDays)

            // Then poll whenever the watcher signals a change
            await withTaskGroup(of: Void.self) { group in
                // DB watcher — polls on iMessage changes
                group.addTask { [weak self] in
                    for await _ in dbWatcher.events {
                        guard !Task.isCancelled else { break }
                        await self?.poll(client: client, db: db, backfillDays: backfillDays)
                    }
                }

                // Heartbeat timer — sends status every 60s when idle
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        guard !Task.isCancelled else { break }
                        // Skip if we just did an ingest within the last 55s
                        if let last = self?.lastIngestTime, Date().timeIntervalSince(last) < 55 {
                            continue
                        }
                        await self?.sendHeartbeat(client: client)
                        await self?.refreshDashboard(client: client)
                    }
                }
            }

            db.close()
        }
    }

    func clearLogs() {
        logEntries.removeAll()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        pollTask?.cancel()
        pollTask = nil
        currentClient = nil
        isRunning = false
        dbConnected = false
    }

    // MARK: - Retry helper

    /// Retries transient errors (timeout, network) with backoff. Does NOT retry auth or server errors.
    private func withRetry<T>(
        label: String,
        maxAttempts: Int = 3,
        backoff: [TimeInterval] = [2, 5],
        operation: () async throws -> T
    ) async throws -> T {
        for attempt in 1...maxAttempts {
            do {
                return try await operation()
            } catch let error as APIError {
                switch error {
                case .networkError(_):
                    if attempt < maxAttempts {
                        let delay = backoff[min(attempt - 1, backoff.count - 1)]
                        log(.warning, "\(label) failed (attempt \(attempt)/\(maxAttempts)), retrying in \(Int(delay))s: \(error.localizedDescription)")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                default:
                    break  // auth/server errors — don't retry
                }
                throw error
            }
        }
        fatalError("unreachable")
    }

    // MARK: - Poll cycle

    private func poll(client: APIClient, db: IMessageDB, backfillDays: Int) async {
        guard !isPolling else {
            log(.info, "Previous poll still running, skipping")
            return
        }

        await MainActor.run { isPolling = true }
        defer { Task { @MainActor in isPolling = false } }

        // Reconnect if needed
        if !db.isConnected {
            log(.warning, "iMessage DB not connected, attempting reconnect…")
            if !(await db.tryReconnect()) {
                await MainActor.run {
                    dbConnected = false
                    lastError = db.lastError
                }
                return
            }
            await MainActor.run { dbConnected = true }
            log(.info, "iMessage DB connection established")
        }

        do {
            var lastRowId = try await withRetry(label: "getWatermark") {
                try await client.getWatermark()
            }

            // First run — backfill from N days ago
            if lastRowId == 0 {
                let cutoff = Date(timeIntervalSinceNow: TimeInterval(-backfillDays * 86400))
                let startId = await db.getStartRowIdSince(cutoff)
                if startId > 0 {
                    lastRowId = startId - 1
                    log(.info, "First run — backfilling from \(backfillDays) days ago (ROWID \(lastRowId))")
                }
            }

            // Initialize event check timestamp to "now" on first run
            // (don't backfill retraction history)
            if lastEventCheckTimestamp == 0 {
                lastEventCheckTimestamp = dateToAppleNanoseconds(Date())
            }

            // Drain loop: keep fetching until all accumulated messages are consumed
            var batchProcessed = 0
            var batchFlagged = 0

            while true {
                let messages = await db.getMessagesSince(lastRowId)
                if messages.isEmpty {
                    log(.info, "No new messages (watermark: \(lastRowId))")
                    break
                }

                log(.info, "Processing \(messages.count) new messages (after ROWID \(lastRowId))")

                let attachmentRowids = messages.filter { $0.hasAttachments }.map { $0.rowid }
                let attachmentMap = attachmentRowids.isEmpty ? [:] : await db.getImageAttachments(forMessageRowids: attachmentRowids)

                var ingestMessages: [IngestMessage] = []
                for m in messages {
                    var senderName: String?
                    if let sid = m.senderId {
                        senderName = await contactResolver.resolve(sid)
                    }

                    var attachments: [IngestAttachment]?
                    if m.hasAttachments, let records = attachmentMap[m.rowid] {
                        attachments = records.compactMap { record in
                            guard FileManager.default.fileExists(atPath: record.filePath),
                                  let data = try? Data(contentsOf: URL(fileURLWithPath: record.filePath)) else {
                                return nil
                            }

                            // Convert HEIC to JPEG since the server's sharp library
                            // may not have HEIC support compiled in
                            if record.mimeType == "image/heic",
                               let image = NSImage(data: data),
                               let tiff = image.tiffRepresentation,
                               let bitmap = NSBitmapImageRep(data: tiff),
                               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                                return IngestAttachment(
                                    filename: record.filename.replacingOccurrences(of: ".heic", with: ".jpg", options: .caseInsensitive),
                                    mimeType: "image/jpeg",
                                    data: jpegData.base64EncodedString()
                                )
                            }

                            return IngestAttachment(
                                filename: record.filename,
                                mimeType: record.mimeType,
                                data: data.base64EncodedString()
                            )
                        }
                        if attachments?.isEmpty == true { attachments = nil }
                    }

                    ingestMessages.append(IngestMessage(
                        rowid: m.rowid,
                        guid: m.guid,
                        text: m.text,
                        date: iso8601.string(from: m.date),
                        isFromMe: m.isFromMe,
                        service: m.service,
                        senderId: m.senderId,
                        senderName: senderName,
                        chatIdentifier: m.chatIdentifier,
                        chatDisplayName: m.chatDisplayName,
                        hasAttachments: m.hasAttachments,
                        attachments: attachments
                    ))
                }

                let result = try await withRetry(label: "ingest(\(ingestMessages.count) msgs)") {
                    try await client.ingest(ingestMessages)
                }
                batchProcessed += result.processed
                batchFlagged += result.flagged

                lastRowId = messages.last!.rowid

                // Fulfill context requests
                for req in result.contextRequests {
                    let contextMsgs = await db.getContextMessages(
                        chatIdentifier: req.chatIdentifier,
                        aroundRowId: req.aroundRowid,
                        count: req.count
                    )
                    if !contextMsgs.isEmpty {
                        var payloads: [ContextMessagePayload] = []
                        for m in contextMsgs {
                            var senderName: String?
                            if let sid = m.senderId {
                                senderName = await contactResolver.resolve(sid)
                            }
                            payloads.append(ContextMessagePayload(
                                rowid: m.rowid,
                                guid: m.guid,
                                text: m.text,
                                date: iso8601.string(from: m.date),
                                isFromMe: m.isFromMe,
                                senderId: m.senderId,
                                senderName: senderName,
                                chatIdentifier: m.chatIdentifier,
                                chatDisplayName: m.chatDisplayName
                            ))
                        }
                        try await client.sendContext(
                            flaggedMessageId: req.flaggedMessageId,
                            messages: payloads
                        )
                        log(.info, "Sent \(contextMsgs.count) context messages for flagged message \(req.flaggedMessageId)")
                    }
                }

                if messages.count < 100 { break }
            }

            let processed = batchProcessed
            let flagged = batchFlagged
            let cStatus = contactResolver.authorized
                ? "\(contactResolver.contactCount) contacts"
                : contactResolver.lastError ?? "Not authorized"
            await MainActor.run {
                lastPollTime = Date()
                lastError = nil
                totalProcessed += processed
                totalFlagged += flagged
                contactsStatus = cStatus
            }

            lastIngestTime = Date()
            await sendHeartbeat(client: client, lastBatchSize: batchProcessed)
            await refreshDashboard(client: client)

            // Check for retracted/edited messages
            let messageEvents = await db.getRetractedOrEditedMessages(since: lastEventCheckTimestamp)
            if !messageEvents.isEmpty {
                var payloads: [MessageEventPayload] = []
                var maxTimestamp: Int64 = lastEventCheckTimestamp

                for event in messageEvents {
                    var senderName: String?
                    if let sid = event.senderId {
                        senderName = await contactResolver.resolve(sid)
                    }
                    payloads.append(MessageEventPayload(
                        guid: event.guid,
                        eventType: event.eventType,
                        chatIdentifier: event.chatIdentifier,
                        sender: senderName ?? event.senderId,
                        eventTimestamp: iso8601.string(from: event.eventTimestamp),
                        editedText: event.editedText
                    ))

                    // Track the max Apple timestamp we've seen
                    let appleTs = dateToAppleNanoseconds(event.eventTimestamp)
                    if appleTs > maxTimestamp {
                        maxTimestamp = appleTs
                    }
                }

                do {
                    let eventsResult = try await withRetry(label: "sendEvents(\(payloads.count))") {
                        try await client.sendEvents(payloads)
                    }
                    lastEventCheckTimestamp = maxTimestamp
                    if eventsResult.flagged > 0 {
                        log(.warning, "Detected \(eventsResult.flagged) flagged unsent/edited messages")
                    } else {
                        log(.info, "Reported \(payloads.count) unsent/edited message events")
                    }
                } catch {
                    log(.error, "Failed to send message events: \(error.localizedDescription)")
                }
            }

            // Sync contacts periodically (every 6 hours)
            if lastContactSync == nil || Date().timeIntervalSince(lastContactSync!) > 6 * 3600 {
                let entries = await contactResolver.allContacts().map {
                    ContactEntry(identifier: $0.identifier, name: $0.name)
                }
                if !entries.isEmpty {
                    try await client.syncContacts(entries)
                    lastContactSync = Date()
                    log(.info, "Synced \(entries.count) contacts to server")
                }
            }

        } catch {
            let detail: String
            if let urlError = error as? URLError {
                detail = "URLError \(urlError.code.rawValue): \(urlError.localizedDescription)"
            } else if let apiError = error as? APIError {
                detail = "APIError: \(apiError.localizedDescription)"
            } else {
                detail = "\(error)"
            }
            log(.error, "Poll failed: \(detail)")
            await MainActor.run { errorCount += 1 }
            await MainActor.run {
                lastError = detail
                lastPollTime = Date()
            }
            await sendHeartbeat(client: client)
        }
    }

    private func pollNotes(client: APIClient, notesDb: NotesDB) async {
        do {
            let serverTimestamp = try await client.getNotesWatermark()
            var lastTimestamp = serverTimestamp

            // Poll in batches until drained
            while true {
                let notes = await notesDb.getNotesSince(lastTimestamp, limit: 100)
                guard !notes.isEmpty else { break }

                let messages = notes.map { note -> IngestMessage in
                    // Truncate very long notes to ~4000 chars
                    var body = note.body
                    if body.count > 4000 {
                        body = String(body.prefix(4000)) + " [truncated, \(note.body.count) characters total]"
                    }

                    return IngestMessage(
                        rowid: note.id,
                        guid: "notes:\(note.id)",
                        text: body,
                        date: iso8601.string(from: note.modificationDate),
                        isFromMe: true,
                        service: "notes",
                        senderId: nil,
                        senderName: nil,
                        chatIdentifier: note.title,
                        chatDisplayName: note.folder,
                        hasAttachments: false,
                        attachments: nil
                    )
                }

                let response = try await client.ingest(messages)
                notesProcessed += response.processed
                notesFlagged += response.flagged

                if response.flagged > 0 {
                    log(.warning, "Notes: flagged \(response.flagged) of \(response.processed)")
                } else {
                    log(.info, "Notes: processed \(response.processed)")
                }

                lastTimestamp = notes.last!.modificationDate.timeIntervalSinceReferenceDate

                // If we got fewer than the limit, we've drained all changes
                if notes.count < 100 { break }
            }
        } catch APIError.unauthorized {
            log(.error, "Notes: unauthorized — check API key")
        } catch {
            log(.error, "Notes poll failed: \(error.localizedDescription)")
        }
    }

    func markReviewed(messageId: Int) async {
        guard let client = currentClient else { return }
        do {
            try await client.markReviewed(messageId: messageId)
            await MainActor.run {
                recentFlagged.removeAll { $0.id == messageId }
                if unreviewedCount > 0 { unreviewedCount -= 1 }
            }
            log(.info, "Marked message \(messageId) as reviewed")
        } catch {
            log(.error, "Failed to mark reviewed: \(error.localizedDescription)")
        }
    }

    private func refreshDashboard(client: APIClient) async {
        do {
            let stats = try await client.getStats()
            let recent = try await client.getRecentFlagged(limit: 5)
            await MainActor.run {
                unreviewedCount = stats.unreviewed
                recentFlagged = recent
            }
        } catch {
            // Non-fatal — dashboard data is optional
            log(.warning, "Dashboard refresh failed: \(error.localizedDescription)")
        }
    }

    private func sendHeartbeat(client: APIClient, lastBatchSize: Int = 0) async {
        let heartbeat = HeartbeatRequest(
            deviceId: Self.deviceId,
            deviceName: Host.current().localizedName ?? "Unknown Mac",
            osVersion: Self.osVersion,
            appVersion: Self.appVersion,
            messagesProcessed: totalProcessed,
            messagesFlagged: totalFlagged,
            lastBatchSize: lastBatchSize,
            errorCount: errorCount,
            lastError: lastError,
            uptimeSeconds: Int(Date().timeIntervalSince(appLaunchTime))
        )
        do {
            try await client.sendHeartbeat(heartbeat)
        } catch {
            log(.warning, "Heartbeat failed: \(error.localizedDescription)")
        }
    }
}
