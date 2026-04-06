import Foundation
import SQLite3

// MARK: - Model

struct IMessageRecord {
    let rowid: Int
    let guid: String
    let text: String
    let date: Date
    let isFromMe: Bool
    let service: String
    let senderId: String?
    let chatIdentifier: String?
    let chatDisplayName: String?
    let hasAttachments: Bool
}

struct AttachmentRecord {
    let messageRowid: Int
    let filename: String
    let mimeType: String
    let filePath: String
}

struct IMessageEvent {
    let rowid: Int
    let guid: String
    let chatIdentifier: String?
    let senderId: String?
    let eventType: String  // "unsent" or "edited"
    let editedText: String?
    let eventTimestamp: Date
}

// MARK: - Apple timestamp conversion

// Apple epoch: 2001-01-01T00:00:00Z in seconds since Unix epoch
private let appleEpochOffset: TimeInterval = 978_307_200

private func appleTimestampToDate(_ nanoseconds: Int64) -> Date {
    let seconds = TimeInterval(nanoseconds) / 1_000_000_000 + appleEpochOffset
    return Date(timeIntervalSince1970: seconds)
}

func dateToAppleNanoseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000)
}

// SQLite transient destructor — tells SQLite to copy bound data immediately
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - IMessageDB

final class IMessageDB: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.parentalthings.imessagedb")
    private var db: OpaquePointer?
    private(set) var lastError: String?

    let dbPath: String

    init(dbPath: String = NSHomeDirectory() + "/Library/Messages/chat.db") {
        self.dbPath = dbPath
        connect()
    }

    deinit { close() }

    var isConnected: Bool { db != nil }

    // MARK: Sync implementations

    /// Returns the lowest ROWID for messages at or after the given date, or 0 if none.
    private func getStartRowIdSinceSync(_ date: Date) -> Int {
        guard connect() else { return 0 }

        let sql = "SELECT MIN(ROWID) FROM message WHERE date >= ?"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }

        sqlite3_bind_int64(stmt, 1, dateToAppleNanoseconds(date))

        if sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    /// Fetches messages with ROWID > lastRowId, up to `limit`.
    private func getMessagesSinceSync(_ lastRowId: Int, limit: Int = 100) -> [IMessageRecord] {
        guard connect() else { return [] }

        let sql = """
            SELECT m.ROWID, m.guid, m.text, m.date, m.is_from_me, m.service,
                   h.id AS sender_id, c.chat_identifier, c.display_name,
                   m.cache_has_attachments, m.attributedBody
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE m.ROWID > ?
                  AND ((m.text IS NOT NULL AND m.text != '') OR m.attributedBody IS NOT NULL OR m.cache_has_attachments = 1)
                  AND m.associated_message_type = 0
            ORDER BY m.ROWID ASC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        sqlite3_bind_int64(stmt, 1, Int64(lastRowId))
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var results: [IMessageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readMessageRow(stmt!))
        }
        return results
    }

    /// Fetches context messages around a ROWID in a specific chat.
    private func getContextMessagesSync(chatIdentifier: String, aroundRowId: Int, count: Int = 5) -> [IMessageRecord] {
        guard connect() else { return [] }

        let hasContent = "((m2.text IS NOT NULL AND m2.text != '') OR m2.attributedBody IS NOT NULL)"

        let sql = """
            SELECT m.ROWID, m.guid, m.text, m.date, m.is_from_me, m.service,
                   h.id AS sender_id, c.chat_identifier, c.display_name,
                   m.cache_has_attachments, m.attributedBody
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE c.chat_identifier = ?
                  AND ((m.text IS NOT NULL AND m.text != '') OR m.attributedBody IS NOT NULL)
                  AND m.associated_message_type = 0
                  AND m.ROWID IN (
                    SELECT ROWID FROM (
                      SELECT m2.ROWID FROM message m2
                      JOIN chat_message_join cmj2 ON m2.ROWID = cmj2.message_id
                      JOIN chat c2 ON cmj2.chat_id = c2.ROWID
                      WHERE c2.chat_identifier = ?
                        AND \(hasContent)
                        AND m2.associated_message_type = 0
                        AND m2.ROWID <= ?
                      ORDER BY m2.ROWID DESC LIMIT ?
                    )
                    UNION
                    SELECT ROWID FROM (
                      SELECT m2.ROWID FROM message m2
                      JOIN chat_message_join cmj2 ON m2.ROWID = cmj2.message_id
                      JOIN chat c2 ON cmj2.chat_id = c2.ROWID
                      WHERE c2.chat_identifier = ?
                        AND \(hasContent)
                        AND m2.associated_message_type = 0
                        AND m2.ROWID > ?
                      ORDER BY m2.ROWID ASC LIMIT ?
                    )
                  )
            ORDER BY m.date ASC
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        bindText(stmt, 1, chatIdentifier)
        bindText(stmt, 2, chatIdentifier)
        sqlite3_bind_int64(stmt, 3, Int64(aroundRowId))
        sqlite3_bind_int(stmt, 4, Int32(count + 1))
        bindText(stmt, 5, chatIdentifier)
        sqlite3_bind_int64(stmt, 6, Int64(aroundRowId))
        sqlite3_bind_int(stmt, 7, Int32(count))

        var results: [IMessageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readMessageRow(stmt!))
        }
        return results
    }

    /// Fetches messages that were retracted or edited since lastCheck timestamp.
    /// Uses Apple nanosecond timestamps for date_retracted and date_edited columns.
    private func getRetractedOrEditedMessagesSync(since lastCheck: Int64) -> [IMessageEvent] {
        guard connect() else { return [] }

        let sql = """
            SELECT m.ROWID, m.guid, c.chat_identifier, h.id AS sender_id,
                   m.date_retracted, m.date_edited, m.text, m.attributedBody
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
            LEFT JOIN chat c ON cmj.chat_id = c.ROWID
            WHERE (m.date_retracted > ? OR m.date_edited > ?)
            ORDER BY m.ROWID ASC
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        sqlite3_bind_int64(stmt, 1, lastCheck)
        sqlite3_bind_int64(stmt, 2, lastCheck)

        var results: [IMessageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = stmt!
            let dateRetracted = sqlite3_column_int64(s, 4)
            let dateEdited = sqlite3_column_int64(s, 5)
            // Current message text (for edited messages, this is the edited version)
            let currentText = columnText(s, 6) ?? extractAttributedBodyText(s, 7)

            if dateRetracted > lastCheck {
                results.append(IMessageEvent(
                    rowid: Int(sqlite3_column_int64(s, 0)),
                    guid: String(cString: sqlite3_column_text(s, 1)),
                    chatIdentifier: columnText(s, 2),
                    senderId: columnText(s, 3),
                    eventType: "unsent",
                    editedText: nil,
                    eventTimestamp: appleTimestampToDate(dateRetracted)
                ))
            }

            if dateEdited > lastCheck {
                results.append(IMessageEvent(
                    rowid: Int(sqlite3_column_int64(s, 0)),
                    guid: String(cString: sqlite3_column_text(s, 1)),
                    chatIdentifier: columnText(s, 2),
                    senderId: columnText(s, 3),
                    eventType: "edited",
                    editedText: currentText,
                    eventTimestamp: appleTimestampToDate(dateEdited)
                ))
            }
        }
        return results
    }

    /// Fetches image attachments for the given message ROWIDs.
    private func getImageAttachmentsSync(forMessageRowids rowids: [Int]) -> [Int: [AttachmentRecord]] {
        guard connect(), !rowids.isEmpty else { return [:] }

        let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT maj.message_id, a.filename, a.mime_type, a.filename AS file_path
            FROM message_attachment_join maj
            JOIN attachment a ON maj.attachment_id = a.ROWID
            WHERE maj.message_id IN (\(placeholders))
              AND a.mime_type IN ('image/jpeg', 'image/png', 'image/heic')
              AND a.filename IS NOT NULL
            ORDER BY maj.message_id ASC
            """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }

        for (i, rowid) in rowids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(i + 1), Int64(rowid))
        }

        var results: [Int: [AttachmentRecord]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let s = stmt!
            let messageRowid = Int(sqlite3_column_int64(s, 0))
            let filename = columnText(s, 1) ?? "unknown"
            let mimeType = columnText(s, 2) ?? "image/jpeg"
            var filePath = columnText(s, 3) ?? ""

            // iMessage stores paths like "~/Library/Messages/Attachments/..."
            if filePath.hasPrefix("~") {
                filePath = NSHomeDirectory() + String(filePath.dropFirst())
            }

            let record = AttachmentRecord(
                messageRowid: messageRowid,
                filename: filename,
                mimeType: mimeType,
                filePath: filePath
            )
            results[messageRowid, default: []].append(record)
        }
        return results
    }

    func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: Async wrappers

    private func onQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    func getStartRowIdSince(_ date: Date) async -> Int {
        await onQueue { self.getStartRowIdSinceSync(date) }
    }

    func getMessagesSince(_ lastRowId: Int, limit: Int = 100) async -> [IMessageRecord] {
        await onQueue { self.getMessagesSinceSync(lastRowId, limit: limit) }
    }

    func getContextMessages(chatIdentifier: String, aroundRowId: Int, count: Int = 5) async -> [IMessageRecord] {
        await onQueue { self.getContextMessagesSync(chatIdentifier: chatIdentifier, aroundRowId: aroundRowId, count: count) }
    }

    func getRetractedOrEditedMessages(since lastCheck: Int64) async -> [IMessageEvent] {
        await onQueue { self.getRetractedOrEditedMessagesSync(since: lastCheck) }
    }

    func getImageAttachments(forMessageRowids rowids: [Int]) async -> [Int: [AttachmentRecord]] {
        await onQueue { self.getImageAttachmentsSync(forMessageRowids: rowids) }
    }

    @discardableResult
    func tryReconnect() async -> Bool {
        await onQueue { self.db != nil ? true : self.connect() }
    }

    // MARK: Private

    @discardableResult
    private func connect() -> Bool {
        if db != nil { return true }

        // READWRITE is needed so SQLite can access the -shm file for WAL
        // coordination. Without it, only checkpointed data is visible and
        // recent messages written to the WAL are silently ignored.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)

        if rc != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            lastError = "Cannot open \(dbPath): \(msg). Grant Full Disk Access in System Settings > Privacy & Security."
            sqlite3_close(db)
            db = nil
            return false
        }

        sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
        lastError = nil
        return true
    }

    private func readMessageRow(_ stmt: OpaquePointer) -> IMessageRecord {
        // Prefer the text column; fall back to extracting from attributedBody (col 10)
        let text = columnText(stmt, 2)
            ?? extractAttributedBodyText(stmt, 10)
            ?? ""

        return IMessageRecord(
            rowid: Int(sqlite3_column_int64(stmt, 0)),
            guid: String(cString: sqlite3_column_text(stmt, 1)),
            text: text,
            date: appleTimestampToDate(sqlite3_column_int64(stmt, 3)),
            isFromMe: sqlite3_column_int(stmt, 4) == 1,
            service: columnText(stmt, 5) ?? "iMessage",
            senderId: columnText(stmt, 6),
            chatIdentifier: columnText(stmt, 7),
            chatDisplayName: columnText(stmt, 8),
            hasAttachments: sqlite3_column_int(stmt, 9) == 1
        )
    }

    /// Extracts plain text from an attributedBody blob column.
    /// The blob is an NSKeyedArchiver-encoded NSAttributedString.
    private func extractAttributedBodyText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(stmt, col) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, col))
        guard length > 0 else { return nil }
        let data = Data(bytes: bytes, count: length)

        // Try NSKeyedUnarchiver (binary plist / NSKeyedArchiver format)
        if let text = unarchiveAttributedString(data) { return text }

        // Fallback: scan the typedstream binary for the UTF-8 text payload
        return scanTypedStreamForText(data)
    }

    private func unarchiveAttributedString(_ data: Data) -> String? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        let obj = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        guard let attrStr = obj as? NSAttributedString else { return nil }
        let text = attrStr.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func scanTypedStreamForText(_ data: Data) -> String? {
        // In the legacy typedstream format the string content follows
        // a 0x01 0x2B ('+') marker, then a length prefix, then UTF-8 bytes.
        let bytes = [UInt8](data)
        let count = bytes.count
        var i = 0
        while i < count - 2 {
            if bytes[i] == 0x01, bytes[i + 1] == 0x2B {
                var offset = i + 2
                guard offset < count else { i += 1; continue }
                let strLen: Int
                if bytes[offset] & 0x80 == 0 {
                    strLen = Int(bytes[offset])
                    offset += 1
                } else {
                    guard offset + 4 < count else { i += 1; continue }
                    strLen = Int(bytes[offset + 1])
                           | Int(bytes[offset + 2]) << 8
                           | Int(bytes[offset + 3]) << 16
                           | Int(bytes[offset + 4]) << 24
                    offset += 5
                }
                if strLen > 0, offset + strLen <= count,
                   let text = String(data: Data(bytes[offset..<(offset + strLen)]), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    return text
                }
            }
            i += 1
        }
        return nil
    }

    private func columnText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        _ = value.withCString { ptr in
            sqlite3_bind_text(stmt, index, ptr, -1, SQLITE_TRANSIENT)
        }
    }
}
