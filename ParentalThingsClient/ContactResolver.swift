@preconcurrency import Contacts
import os

private let logger = Logger(subsystem: "com.parentalthings.client", category: "contacts")

final class ContactResolver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.parentalthings.contacts")
    private var phoneMap: [String: String] = [:]  // normalized digits -> name
    private var emailMap: [String: String] = [:]  // lowercase email -> name
    private var loaded = false

    private(set) var contactCount = 0
    private(set) var lastError: String?
    private(set) var authorized = false

    /// Resolve a phone number or email to a contact name.
    func resolve(_ identifier: String) async -> String? {
        if !loaded { await load() }
        if identifier.contains("@") {
            return emailMap[identifier.lowercased()]
        }
        let normalized = normalizePhone(identifier)
        guard normalized.count >= 7 else { return nil }
        return phoneMap[normalized]
    }

    /// Returns all contacts as (identifier, name) pairs for syncing to the server.
    func allContacts() async -> [(identifier: String, name: String)] {
        if !loaded { await load() }
        var result: [(String, String)] = []
        for (phone, name) in phoneMap {
            result.append((phone, name))
        }
        for (email, name) in emailMap {
            result.append((email, name))
        }
        return result
    }

    /// Force a reload on next access (e.g. after Contacts change notification).
    func invalidate() {
        loaded = false
        phoneMap.removeAll()
        emailMap.removeAll()
    }

    /// Request contacts access. Call early (before polling) so the system
    /// dialog appears reliably — blocking with a semaphore inside a Swift
    /// Task can deadlock the cooperative thread pool.
    func requestAccessIfNeeded() async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        logger.info("Contacts auth status before request: \(status.rawValue)")

        // On macOS 14+ (Sonoma), sandboxed apps may report .denied before the
        // user has been prompted. Always call requestAccess unless already authorized.
        guard status != .authorized else {
            authorized = true
            return
        }

        let store = CNContactStore()
        do {
            authorized = try await store.requestAccess(for: .contacts)
        } catch {
            authorized = false
            logger.error("requestAccess threw: \(error.localizedDescription)")
        }

        if authorized {
            logger.info("Contacts access granted")
        } else {
            lastError = "Contacts access denied — enable in System Settings > Privacy & Security > Contacts"
            logger.warning("Contacts access denied (status was \(status.rawValue))")
        }
    }

    // MARK: - Private

    private func load() async {
        loaded = true

        let status = CNContactStore.authorizationStatus(for: .contacts)
        logger.info("Contacts authorization status: \(status.rawValue)")

        switch status {
        case .authorized, .limited:
            authorized = true
        default:
            authorized = false
            lastError = status == .notDetermined
                ? "Contacts access not requested"
                : "Contacts access not authorized (status \(status.rawValue))"
            logger.warning("Contacts access not authorized (status: \(status.rawValue))")
            return
        }

        let result: (phones: [String: String], emails: [String: String], error: String?) = await withCheckedContinuation { continuation in
            queue.async {
                let store = CNContactStore()
                let keys: [CNKeyDescriptor] = [
                    CNContactGivenNameKey as CNKeyDescriptor,
                    CNContactFamilyNameKey as CNKeyDescriptor,
                    CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor,
                ]
                let request = CNContactFetchRequest(keysToFetch: keys)

                var phones: [String: String] = [:]
                var emails: [String: String] = [:]

                do {
                    try store.enumerateContacts(with: request) { contact, _ in
                        let name = [contact.givenName, contact.familyName]
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                        guard !name.isEmpty else { return }

                        for phone in contact.phoneNumbers {
                            let normalized = self.normalizePhone(phone.value.stringValue)
                            if normalized.count >= 7 {
                                phones[normalized] = name
                            }
                        }

                        for email in contact.emailAddresses {
                            emails[(email.value as String).lowercased()] = name
                        }
                    }
                    continuation.resume(returning: (phones, emails, nil))
                } catch {
                    continuation.resume(returning: ([:], [:], error.localizedDescription))
                }
            }
        }

        if let error = result.error {
            self.lastError = error
            logger.error("Failed to load contacts: \(error)")
        } else {
            self.phoneMap = result.phones
            self.emailMap = result.emails
            self.contactCount = result.phones.count + result.emails.count
            self.lastError = nil
            logger.info("Contacts loaded: \(result.phones.count) phones, \(result.emails.count) emails")
        }
    }

    private func normalizePhone(_ phone: String) -> String {
        let digits = phone.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        let str = String(String.UnicodeScalarView(digits))
        return String(str.suffix(10))
    }
}
