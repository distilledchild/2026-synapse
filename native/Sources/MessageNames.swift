import Foundation

// Messages' participant name is the label shown by Messages, including its choice
// between duplicate cards/accounts. chat.db does not contain this label.
struct MessageNameRequest: Codable, Sendable {
    let chatIDs: [String]
    static let batchSize = 24
    static func isDirectChat(_ id: String) -> Bool {
        let parts = id.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        return parts.count == 3 && ["any", "iMessage", "SMS", "RCS"].contains(String(parts[0])) &&
            parts[1] == "-" && !parts[2].isEmpty && id.utf8.count <= 1024 &&
            !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    var isValid: Bool {
        !chatIDs.isEmpty && chatIDs.count <= Self.batchSize &&
            Set(chatIDs).count == chatIDs.count && chatIDs.allSatisfy(Self.isDirectChat)
    }
}

enum MessageNameError: String, Error, Codable {
    case permissionDenied, unavailable, invalidRequest
}

struct MessageNameResponse: Codable, Sendable {
    var names: [String: String] = [:]
    var error: MessageNameError? = nil
}

protocol MessageNamesProviding: Sendable {
    func lookup(_ chatIDs: Set<String>) async throws -> [String: String]
}

struct NoMessageNames: MessageNamesProviding {
    func lookup(_ chatIDs: Set<String>) async throws -> [String: String] { [:] }
}

struct AppleMessageNames: MessageNamesProviding {
    var executableURL = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("SynapseNames")
    var timeout: TimeInterval = 20

    func lookup(_ chatIDs: Set<String>) async throws -> [String: String] {
        let ids = chatIDs.filter(MessageNameRequest.isDirectChat).sorted()
        guard !ids.isEmpty else { return [:] }
        guard let executableURL else { throw MessageNameError.unavailable }
        var names: [String: String] = [:]
        for offset in stride(from: 0, to: ids.count, by: MessageNameRequest.batchSize) {
            let request = MessageNameRequest(chatIDs: Array(ids[offset..<min(offset + MessageNameRequest.batchSize, ids.count)]))
            let payload = try JSONEncoder().encode(request)
            let result = try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = executableURL
                let input = Pipe(), output = Pipe()
                process.standardInput = input; process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { throw MessageNameError.unavailable }
                // Drain while the helper runs: a batch can exceed the pipe buffer.
                let reader = Task.detached { try? output.fileHandleForReading.readToEnd() }
                do {
                    try input.fileHandleForWriting.write(contentsOf: payload)
                    try input.fileHandleForWriting.close()
                } catch {
                    try? input.fileHandleForWriting.close()
                    process.terminate()
                    throw MessageNameError.unavailable
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
                while process.isRunning && ContinuousClock.now < deadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning { process.terminate(); throw MessageNameError.unavailable }
                guard process.terminationStatus == 0, let data = await reader.value,
                      data.count <= 262_144,
                      let response = try? JSONDecoder().decode(MessageNameResponse.self, from: data) else {
                    throw MessageNameError.unavailable
                }
                if let error = response.error { throw error }
                return response.names.filter { request.chatIDs.contains($0.key) && $0.value.utf8.count <= 4096 }
            }.value
            names.merge(result) { _, new in new }
        }
        return names
    }
}

enum MessageNameScript {
    // Read-only, fixed source. IDs travel as Apple event descriptors, never code.
    static let source = """
    on readNames(chatIDs)
        set foundNames to {}
        with timeout of 10 seconds
            tell application id "com.apple.MobileSMS"
                repeat with requestedID in chatIDs
                    try
                        set chatID to requestedID as text
                        set targetChat to chat id chatID
                        if (id of targetChat as text) is equal to chatID then
                            set people to participants of targetChat
                            set labels to {}
                            repeat with person in people
                                set personName to full name of person
                                if personName is missing value or personName is "" then set personName to name of person
                                if personName is not missing value then
                                    set end of labels to {handle of person as text, personName as text}
                                end if
                            end repeat
                            set end of foundNames to {chatID, labels}
                        end if
                    on error errorText number errorCode
                        if errorCode is -1743 then return "permissionDenied"
                        -- One unavailable chat must not hide names in other chats.
                    end try
                end repeat
            end tell
        end timeout
        return foundNames
    end readNames
    """

    static func event(for request: MessageNameRequest) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: 0x61736372, eventID: 0x70736272,
            targetDescriptor: nil, returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: "readnames"), forKeyword: 0x736e616d)
        let ids = NSAppleEventDescriptor.list()
        for (index, id) in request.chatIDs.enumerated() { ids.insert(NSAppleEventDescriptor(string: id), at: index + 1) }
        let arguments = NSAppleEventDescriptor.list(); arguments.insert(ids, at: 1)
        event.setParam(arguments, forKeyword: 0x2d2d2d2d)
        return event
    }

    static func matchingName(chatID: String, participants: [(handle: String, name: String)]) -> String? {
        guard MessageNameRequest.isDirectChat(chatID) else { return nil }
        let address = String(chatID.split(separator: ";", maxSplits: 2)[2])
        func normalized(_ value: String) -> String {
            if value.contains("@") { return value.lowercased() }
            return value.filter { !" ()-.".contains($0) }
        }
        let matches = participants.filter { normalized($0.handle) == normalized(address) }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.utf8.count <= 4096 && normalized($0) != normalized(address) }
        // Never guess a participant based on only the last digits or another chat.
        let unique = Set(matches)
        return unique.count == 1 ? unique.first : nil
    }

    static func response(from result: NSAppleEventDescriptor, request: MessageNameRequest) -> MessageNameResponse {
        if result.stringValue == "permissionDenied" { return MessageNameResponse(error: .permissionDenied) }
        var names: [String: String] = [:]
        guard result.numberOfItems > 0 else { return MessageNameResponse() }
        for index in 1...min(result.numberOfItems, MessageNameRequest.batchSize) {
            guard let row = result.atIndex(index), let id = row.atIndex(1)?.stringValue,
                  request.chatIDs.contains(id), let people = row.atIndex(2), people.numberOfItems > 0 else { continue }
            var participants: [(String, String)] = []
            for personIndex in 1...min(people.numberOfItems, 100) {
                guard let person = people.atIndex(personIndex), let handle = person.atIndex(1)?.stringValue,
                      let name = person.atIndex(2)?.stringValue else { continue }
                participants.append((handle, name))
            }
            names[id] = matchingName(chatID: id, participants: participants)
        }
        return MessageNameResponse(names: names)
    }
}
