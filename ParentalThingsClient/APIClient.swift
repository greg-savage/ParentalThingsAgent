import Foundation

// MARK: - Request / Response Models

struct IngestAttachment: Encodable {
    let filename: String
    let mimeType: String
    let data: String  // base64-encoded
}

struct IngestMessage: Encodable {
    let rowid: Int
    let guid: String
    let text: String
    let date: String
    let isFromMe: Bool
    let service: String
    let senderId: String?
    let senderName: String?
    let chatIdentifier: String?
    let chatDisplayName: String?
    let hasAttachments: Bool
    let attachments: [IngestAttachment]?
}

struct IngestRequest: Encodable {
    let messages: [IngestMessage]
}

struct ContextRequestItem: Decodable {
    let chatIdentifier: String
    let aroundRowid: Int
    let flaggedMessageId: Int
    let count: Int
}

struct IngestResponse: Decodable {
    let processed: Int
    let flagged: Int
    let contextRequests: [ContextRequestItem]
}

struct WatermarkResponse: Decodable {
    let lastProcessedRowid: Int
}

struct NotesWatermarkResponse: Decodable {
    let lastNotesTimestamp: String
}

struct ContextPayload: Encodable {
    let flaggedMessageId: Int
    let messages: [ContextMessagePayload]
}

struct ContextMessagePayload: Encodable {
    let rowid: Int
    let guid: String
    let text: String
    let date: String
    let isFromMe: Bool
    let senderId: String?
    let senderName: String?
    let chatIdentifier: String?
    let chatDisplayName: String?
}

struct ContactEntry: Encodable {
    let identifier: String
    let name: String
}

struct ContactsSyncRequest: Encodable {
    let contacts: [ContactEntry]
}

struct HeartbeatRequest: Encodable {
    let deviceId: String
    let deviceName: String
    let osVersion: String
    let appVersion: String
    let messagesProcessed: Int
    let messagesFlagged: Int
    let lastBatchSize: Int
    let errorCount: Int
    let lastError: String?
    let uptimeSeconds: Int
}

struct MessageEventPayload: Encodable {
    let guid: String
    let eventType: String
    let chatIdentifier: String?
    let sender: String?
    let eventTimestamp: String
    let editedText: String?
}

struct EventsRequest: Encodable {
    let events: [MessageEventPayload]
}

struct EventsResponse: Decodable {
    let processed: Int
    let flagged: Int
}

// MARK: - Dashboard Models

struct StatsResponse: Decodable {
    let total: Int
    let unreviewed: Int
}

struct RecentFlaggedMessage: Decodable, Identifiable {
    let id: Int
    let sender: String
    let messageText: String
    let severity: String
    let timestamp: String
    let isReviewed: Bool
    let chatIdentifier: String
}

// MARK: - Error

enum APIError: LocalizedError {
    case badServerURL
    case unauthorized
    case serverError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .badServerURL:         return "Invalid server URL"
        case .unauthorized:         return "Invalid API key"
        case .serverError(let m):   return m
        case .networkError(let e):  return e.localizedDescription
        }
    }
}

// MARK: - APIClient

import os

private let logger = Logger(subsystem: "com.parentalthings.client", category: "api")

final class APIClient {
    let serverURL: String
    let apiKey: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    init(serverURL: String, apiKey: String) {
        self.serverURL = serverURL
        self.apiKey = apiKey
    }

    // MARK: Endpoints

    func getWatermark() async throws -> Int {
        let resp: WatermarkResponse = try await perform(makeRequest("/api/watermark"))
        return resp.lastProcessedRowid
    }

    func getNotesWatermark() async throws -> TimeInterval {
        let resp: NotesWatermarkResponse = try await perform(makeRequest("/api/watermark/notes"))
        if resp.lastNotesTimestamp == "0" {
            return 0
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: resp.lastNotesTimestamp) {
            return date.timeIntervalSinceReferenceDate
        }
        return 0
    }

    func ingest(_ messages: [IngestMessage]) async throws -> IngestResponse {
        let body = try JSONEncoder().encode(IngestRequest(messages: messages))
        var req = try makeRequest("/api/ingest", method: "POST", body: body)
        req.timeoutInterval = 120  // AI analysis can be slow for large batches
        return try await perform(req)
    }

    func sendContext(flaggedMessageId: Int, messages: [ContextMessagePayload]) async throws {
        let body = try JSONEncoder().encode(
            ContextPayload(flaggedMessageId: flaggedMessageId, messages: messages)
        )
        let _: [String: Bool] = try await perform(makeRequest("/api/context", method: "POST", body: body))
    }

    func syncContacts(_ contacts: [ContactEntry]) async throws {
        let body = try JSONEncoder().encode(ContactsSyncRequest(contacts: contacts))
        let _: [String: Bool] = try await perform(makeRequest("/api/contacts", method: "POST", body: body))
    }

    func sendHeartbeat(_ heartbeat: HeartbeatRequest) async throws {
        let body = try JSONEncoder().encode(heartbeat)
        let _: [String: Bool] = try await perform(makeRequest("/api/heartbeat", method: "POST", body: body))
    }

    func sendEvents(_ events: [MessageEventPayload]) async throws -> EventsResponse {
        let body = try JSONEncoder().encode(EventsRequest(events: events))
        return try await perform(makeRequest("/api/ingest/events", method: "POST", body: body))
    }

    func getStats() async throws -> StatsResponse {
        return try await perform(makeRequest("/api/stats"))
    }

    func getRecentFlagged(limit: Int = 5) async throws -> [RecentFlaggedMessage] {
        return try await perform(makeRequest("/api/flagged?grouped=false&reviewed=false&limit=\(limit)"))
    }

    func markReviewed(messageId: Int) async throws {
        let _: [String: Bool] = try await perform(makeRequest("/api/flagged/\(messageId)/review", method: "POST"))
    }

    // MARK: Private

    private var base: URL? {
        var urlString = serverURL.trimmingCharacters(in: .whitespaces)
        // Ensure explicit port — URLSession in some environments fails without it
        if let url = URL(string: urlString),
           url.port == nil,
           let scheme = url.scheme, let host = url.host {
            let defaultPort = scheme == "https" ? 443 : 80
            urlString = "\(scheme)://\(host):\(defaultPort)\(url.path)"
        }
        return URL(string: urlString)
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let base, let url = URL(string: path, relativeTo: base) else {
            throw APIError.badServerURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func perform<T: Decodable>(_ req: URLRequest) async throws -> T {
        let urlString = req.url?.absoluteString ?? "unknown"
        let method = req.httpMethod ?? "GET"
        logger.debug("\(method, privacy: .public) \(urlString, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch let error as URLError where error.code == .timedOut {
            logger.error("\(method, privacy: .public) \(urlString, privacy: .public) — request timed out after \(req.timeoutInterval, privacy: .public)s")
            throw APIError.networkError(error)
        } catch {
            let desc = (error as? URLError).map { "URLError \($0.code.rawValue): \($0.localizedDescription)" } ?? "\(error)"
            logger.error("\(method, privacy: .public) \(urlString, privacy: .public) — network error: \(desc, privacy: .public)")
            throw APIError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError("No HTTP response")
        }

        logger.debug("\(method, privacy: .public) \(urlString, privacy: .public) — \(http.statusCode, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            return try JSONDecoder().decode(T.self, from: data)
        case 401, 403:
            logger.warning("\(method, privacy: .public) \(urlString, privacy: .public) — unauthorized (\(http.statusCode, privacy: .public))")
            throw APIError.unauthorized
        default:
            let msg = String(data: data, encoding: .utf8) ?? "Server error \(http.statusCode)"
            logger.error("\(method, privacy: .public) \(urlString, privacy: .public) — \(http.statusCode, privacy: .public): \(msg, privacy: .public)")
            throw APIError.serverError(msg)
        }
    }
}
