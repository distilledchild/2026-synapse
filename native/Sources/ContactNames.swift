import Foundation
import Contacts

struct ContactIdentity: Sendable, Equatable {
    let name: String
    var initials: String? { NamePresentation.initials(for: name) }

    static func from(matchingNames: [String]) -> ContactIdentity? {
        let cleaned = matchingNames.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }.sorted()
        var seen = Set<String>()
        let distinct = cleaned.filter {
            seen.insert($0.precomposedStringWithCanonicalMapping.lowercased()).inserted
        }
        guard !distinct.isEmpty else { return nil }
        // Multiple accounts may contain the same person. Preserve different saved
        // labels instead of guessing which record is preferred or hiding every name.
        return ContactIdentity(name: distinct.joined(separator: " / "))
    }
}

enum NamePresentation {
    static func isAddress(_ value: String) -> Bool {
        value.contains("@") || isPhone(value)
    }
    static func isPhone(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.unicodeScalars.allSatisfy(allowed.contains) && text.contains(where: \.isNumber)
    }
    static func initials(for name: String) -> String? {
        guard !isAddress(name) else { return nil }
        let words = (name.components(separatedBy: " / ").first ?? name).split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return nil }
        // Korean/CJK names use one complete character, never a sliced scalar.
        let isCJK = first.unicodeScalars.contains {
            (0xAC00...0xD7AF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) ||
            (0x3040...0x30FF).contains($0.value)
        }
        if isCJK { return String(first) }
        if words.count > 1, let last = words.last?.first,
           first.isASCII, first.isLetter, last.isASCII, last.isLetter {
            return (String(first) + String(last)).uppercased()
        }
        return String(first).uppercased()
    }

    static func directAddress(for message: ChatMessage) -> String? {
        let parts = message.conversationID.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "-" else { return nil }
        if let address = message.conversationAddress, !address.isEmpty { return address }
        return String(parts[2])
    }

    static func title(for message: ChatMessage, names: [String: ContactIdentity], messageNames: [String: String] = [:]) -> String {
        // Preserve user-defined group titles and verified business display names.
        if let display = message.conversationDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty {
            if isAddress(display), let name = messageNames[message.conversationID] { return name }
            if let contact = names[display], isAddress(display) { return contact.name }
            return display
        }
        if directAddress(for: message) != nil, let name = messageNames[message.conversationID] { return name }
        if let address = directAddress(for: message), let contact = names[address] { return contact.name }
        return message.conversationTitle
    }

    static func handles(in snapshot: Snapshot) -> Set<String> {
        var result = Set<String>()
        for message in snapshot.messages {
            if isAddress(message.sender) { result.insert(message.sender) }
            if let address = directAddress(for: message), isAddress(address) { result.insert(address) }
            if let display = message.conversationDisplayName, isAddress(display) { result.insert(display) }
        }
        return result
    }
}

enum ContactAccess: Sendable {
    case notRequested, authorized, denied, restricted
}

protocol ContactProviding: Sendable {
    func authorization() -> ContactAccess
    func requestAccess() async -> Bool
    func lookup(_ handles: Set<String>) async throws -> [String: ContactIdentity]
}

struct AppleContacts: ContactProviding {
    func authorization() -> ContactAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .notDetermined: return .notRequested
        case .authorized: return .authorized
        case .limited: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .restricted
        }
    }
    func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) == true
    }
    func lookup(_ handles: Set<String>) async throws -> [String: ContactIdentity] {
        try await Task.detached(priority: .utility) {
            let store = CNContactStore()
            let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
            var names: [String: ContactIdentity] = [:]
            for handle in handles.sorted() {
                let predicate: NSPredicate
                if handle.contains("@") {
                    predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
                } else if NamePresentation.isPhone(handle) {
                    // Let Contacts handle country codes and phone formatting; no suffix guessing.
                    predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
                } else { continue }
                let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
                let matchedNames = contacts.compactMap { CNContactFormatter.string(from: $0, style: .fullName) }
                names[handle] = ContactIdentity.from(matchingNames: matchedNames)
            }
            return names
        }.value
    }
}
