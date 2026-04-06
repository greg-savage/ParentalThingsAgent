import Foundation
import SQLite3
import Compression

struct NotesRecord {
    let id: Int          // Z_PK
    let title: String    // ZTITLE2, fallback "Untitled Note"
    let body: String     // extracted plain text from ZDATA
    let modificationDate: Date  // ZMODIFICATIONDATE
    let folder: String?  // parent folder title
}

final class NotesDB: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "NotesDB")

    init(path: String) {
        self.path = path
    }

    /// Default NoteStore.sqlite path for iCloud Notes
    static var defaultPath: String? {
        let groupContainers = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
        let notesContainer = groupContainers
            .appendingPathComponent("group.com.apple.notes")
            .appendingPathComponent("NoteStore.sqlite")
        return FileManager.default.fileExists(atPath: notesContainer.path)
            ? notesContainer.path
            : nil
    }

    func getNotesSinceSync(_ lastTimestamp: TimeInterval, limit: Int = 100) -> [NotesRecord] {
        queue.sync {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_close(db) }

            let sql = """
                SELECT
                    n.Z_PK,
                    n.ZTITLE2,
                    n.ZMODIFICATIONDATE,
                    nd.ZDATA,
                    folder.ZTITLE2 AS folder_title
                FROM ZICCLOUDSYNCINGOBJECT n
                LEFT JOIN ZICNOTEDATA nd ON nd.ZNOTE = n.Z_PK
                LEFT JOIN ZICCLOUDSYNCINGOBJECT folder ON n.ZFOLDER = folder.Z_PK
                WHERE n.ZMODIFICATIONDATE > ?
                  AND (n.ZMARKEDFORDELETION IS NULL OR n.ZMARKEDFORDELETION != 1)
                  AND n.ZTYPEUTI = 'com.apple.notes.note'
                ORDER BY n.ZMODIFICATIONDATE ASC
                LIMIT ?
                """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return []
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_double(stmt, 1, lastTimestamp)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var records: [NotesRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(stmt, 0))

                let title: String
                if let cStr = sqlite3_column_text(stmt, 1) {
                    title = String(cString: cStr)
                } else {
                    title = "Untitled Note"
                }

                let modTimestamp = sqlite3_column_double(stmt, 2)
                let modDate = Date(timeIntervalSinceReferenceDate: modTimestamp)

                // Extract body text from ZDATA (gzip-compressed HTML-like content)
                var body = ""
                if let dataBlob = sqlite3_column_blob(stmt, 3) {
                    let dataLen = Int(sqlite3_column_bytes(stmt, 3))
                    let data = Data(bytes: dataBlob, count: dataLen)
                    body = Self.extractTextFromNoteData(data)
                }

                let folder: String?
                if let cStr = sqlite3_column_text(stmt, 4) {
                    folder = String(cString: cStr)
                } else {
                    folder = nil
                }

                // Skip empty notes
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                records.append(NotesRecord(
                    id: id,
                    title: title,
                    body: body,
                    modificationDate: modDate,
                    folder: folder
                ))
            }

            return records
        }
    }

    func getNotesSince(_ lastTimestamp: TimeInterval, limit: Int = 100) async -> [NotesRecord] {
        await withCheckedContinuation { continuation in
            let result = getNotesSinceSync(lastTimestamp, limit: limit)
            continuation.resume(returning: result)
        }
    }

    // MARK: - Text Extraction

    /// Extract plain text from the ZDATA blob.
    /// ZDATA is gzip-compressed protobuf that contains HTML-like note content.
    static func extractTextFromNoteData(_ data: Data) -> String {
        // Try gunzip first
        guard let decompressed = gunzip(data) else {
            // If not gzipped, try raw
            return stripMarkup(String(data: data, encoding: .utf8) ?? "")
        }

        let raw = String(data: decompressed, encoding: .utf8) ?? ""
        return stripMarkup(raw)
    }

    /// Strip HTML tags and common note markup to get plain text
    static func stripMarkup(_ html: String) -> String {
        var text = html
        // Remove HTML tags
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse whitespace
        text = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gunzip data using Apple's Compression framework
    static func gunzip(_ data: Data) -> Data? {
        // Gzip header: 0x1f 0x8b
        guard data.count >= 2, data[0] == 0x1F, data[1] == 0x8B else {
            return nil
        }

        // Skip gzip header (minimum 10 bytes)
        var offset = 10
        let flags = data.count > 3 ? data[3] : 0

        // FEXTRA
        if flags & 0x04 != 0, data.count > offset + 2 {
            let extraLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLen
        }
        // FNAME
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flags & 0x02 != 0 { offset += 2 }

        guard offset < data.count else { return nil }
        guard data.count >= offset + 8 else { return nil }

        let compressed = data.subdata(in: offset..<(data.count - 8)) // strip 8-byte gzip trailer
        let bufferSize = 1024 * 1024 // 1MB max decompressed size
        var decompressed = Data(count: bufferSize)

        let result = compressed.withUnsafeBytes { src in
            decompressed.withUnsafeMutableBytes { dst in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!,
                    bufferSize,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard result > 0 else { return nil }
        decompressed.count = result
        return decompressed
    }
}
